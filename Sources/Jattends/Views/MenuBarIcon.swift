import AppKit

enum MenuBarIcon {
    private static let normalSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none" viewBox="0 0 32 32">
      <path fill="#000" d="M24 27v3H8v-3h16Zm3-3V8a3 3 0 0 0-3-3H8a3 3 0 0 0-3 3v16a3 3 0 0 0 3 3v3a6 6 0 0 1-5.992-5.691L2 24V8a6 6 0 0 1 6-6h16l.309.008A6 6 0 0 1 30 8v16l-.008.309a6 6 0 0 1-5.683 5.683L24 30v-3a3 3 0 0 0 3-3Z"/>
      <path fill="#000" d="M14.714 22v-3.815l-3.428 1.908L10 17.907 13.393 16 10 14.092l1.286-2.184 3.428 1.907V10h2.607v3.815l3.393-1.907L22 14.091 18.607 16 22 17.907l-1.286 2.186-3.393-1.908V22h-2.607Z"/>
    </svg>
    """

    private static let badgeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none" viewBox="0 0 32 32">
      <path fill="#fff" d="M19.072 2a7.942 7.942 0 0 0-1.008 3H8a3 3 0 0 0-3 3v16a3 3 0 0 0 3 3h16a3 3 0 0 0 3-3V13.935a7.94 7.94 0 0 0 3-1.01V24a6 6 0 0 1-6 6H8a6 6 0 0 1-6-6V8a6 6 0 0 1 6-6h11.072Z"/>
      <path fill="#fff" d="M14.714 22v-3.815l-3.428 1.908L10 17.907 13.393 16 10 14.092l1.286-2.184 3.428 1.907V10h2.607v3.815l3.393-1.907L22 14.091 18.607 16 22 17.907l-1.286 2.186-3.393-1.908V22h-2.607Z"/>
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
