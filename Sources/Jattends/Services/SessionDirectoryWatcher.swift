import Foundation
import CoreServices

/// Watches a directory for file changes using FSEvents.
/// Calls the provided callback on the main actor when changes are detected.
final class SessionDirectoryWatcher: @unchecked Sendable {
    private let directory: String
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init(directory: String, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        let pathsToWatch = [directory] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // 300ms coalesce latency
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
