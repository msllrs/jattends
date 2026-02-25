import AppKit

enum MenuBarIcon {
    private static let normalSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none" viewBox="0 0 32 32">
      <path fill="#000" d="M24 27v3H8v-3h16Zm3-3V8a3 3 0 0 0-3-3H8a3 3 0 0 0-3 3v16a3 3 0 0 0 3 3v3a6 6 0 0 1-5.992-5.691L2 24V8a6 6 0 0 1 6-6h16l.309.008A6 6 0 0 1 30 8v16l-.008.309a6 6 0 0 1-5.683 5.683L24 30v-3a3 3 0 0 0 3-3Z"/>
      <path fill="#000" d="M9.94 9.94a1.5 1.5 0 0 1 2.12 0l3 3a1.5 1.5 0 0 1 0 2.12l-3 3a1.5 1.5 0 0 1-2.12-2.12L11.878 14l-1.94-1.94a1.5 1.5 0 0 1 0-2.12ZM21 15.5a1.5 1.5 0 0 1 0 3h-3a1.5 1.5 0 0 1 0-3h3Z"/>
    </svg>
    """

    private static let badgeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none" viewBox="0 0 32 32">
      <path fill="#fff" d="M19.072 2a7.942 7.942 0 0 0-1.008 3H8a3 3 0 0 0-3 3v16a3 3 0 0 0 3 3h16a3 3 0 0 0 3-3V13.935a7.94 7.94 0 0 0 3-1.01V24a6 6 0 0 1-6 6H8a6 6 0 0 1-6-6V8a6 6 0 0 1 6-6h11.072Z"/>
      <path fill="#fff" d="M9.94 9.94a1.5 1.5 0 0 1 2.12 0l3 3a1.5 1.5 0 0 1 0 2.12l-3 3a1.5 1.5 0 0 1-2.12-2.12L11.878 14l-1.94-1.94a1.5 1.5 0 0 1 0-2.12ZM21 15.5a1.5 1.5 0 0 1 0 3h-3a1.5 1.5 0 0 1 0-3h3Z"/>
      <circle cx="26" cy="6" r="5.5" fill="#d77757"/>
    </svg>
    """

    static func buildIcon(badge: Bool) -> NSImage {
        let svgString = badge ? badgeSVG : normalSVG
        guard let data = svgString.data(using: .utf8),
              let img = NSImage(data: data) else {
            return NSImage()
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = !badge
        return img
    }
}
