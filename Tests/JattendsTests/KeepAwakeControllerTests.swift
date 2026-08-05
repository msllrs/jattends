import XCTest
@testable import Jattends

final class KeepAwakeControllerTests: XCTestCase {
    private func makeController(
        pids: @escaping () -> [Int32] = { [] }
    ) -> (KeepAwakeController, commands: () -> [String], complete: (Bool) -> Void) {
        let controller = KeepAwakeController()
        var captured: [String] = []
        var completions: [(Bool) -> Void] = []
        controller.findPids = pids
        controller.runPrivileged = { command, completion in
            captured.append(command)
            completions.append(completion)
        }
        return (controller, { captured }, { ok in completions.removeFirst()(ok) })
    }

    // Reproduces the double-start: clicking the menu row again while the
    // first admin-password dialog is still open must not launch a second
    // instance of the script.
    func testToggleWhileAuthorizationPendingIsIgnored() {
        let (controller, commands, _) = makeController()
        controller.toggle()
        controller.toggle()
        XCTAssertEqual(commands().count, 1, "second toggle during pending auth must be a no-op")
    }

    func testToggleTogglesAgainAfterCompletion() {
        var running: [Int32] = []
        let (controller, commands, complete) = makeController(pids: { running })
        controller.toggle()
        running = [42]
        complete(true)
        controller.toggle()
        XCTAssertEqual(commands().count, 2)
        XCTAssertTrue(commands()[0].contains("nohup"), "first toggle starts")
        XCTAssertEqual(commands()[1], "kill -TERM 42", "second toggle stops the running instance")
    }

    func testOutcomesAreReported() {
        var running: [Int32] = []
        let (controller, _, complete) = makeController(pids: { running })
        var outcomes: [KeepAwakeController.Outcome] = []
        controller.onOutcome = { outcomes.append($0) }

        controller.toggle()            // start…
        complete(true)                 // …authorized
        running = [42]
        controller.toggle()            // stop…
        complete(false)                // …user cancelled the password dialog
        running = []
        controller.toggle()
        complete(true)

        XCTAssertEqual(outcomes, [.started, .failed, .started])
    }

    func testStartCommandInjectsSudoUser() {
        let command = KeepAwakeController.startCommand(
            scriptPath: "/Users/matt/.claude/scripts/awake-until-claude-idle.sh",
            user: "matt"
        )
        // Without SUDO_USER the root-run script resolves ~root and sleeps
        // the Mac immediately — the env injection is load-bearing.
        XCTAssertTrue(command.hasPrefix("SUDO_USER='matt' "))
        XCTAssertTrue(command.contains("nohup '/Users/matt/.claude/scripts/awake-until-claude-idle.sh'"))
        XCTAssertTrue(command.hasSuffix("&"), "must background so osascript returns immediately")
    }

    func testStopCommandUsesTermForCleanupTrap() {
        XCTAssertEqual(KeepAwakeController.stopCommand(pids: [123]), "kill -TERM 123")
        XCTAssertEqual(KeepAwakeController.stopCommand(pids: [123, 456]), "kill -TERM 123 456")
    }
}
