import AppKit

enum MenuBarIcon {
    private static let normalSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" fill="none" viewBox="0 0 36 36">
      <path fill="#fff" d="M26 29v3H10v-3h16Zm3-3V10a3 3 0 0 0-3-3H10a3 3 0 0 0-3 3v16a3 3 0 0 0 3 3v3a6 6 0 0 1-5.992-5.691L4 26V10a6 6 0 0 1 6-6h16l.309.008A6 6 0 0 1 32 10v16l-.008.309a6 6 0 0 1-5.683 5.683L26 32v-3a3 3 0 0 0 3-3Z"/>
      <path fill="#fff" d="M16.714 24v-3.815l-3.428 1.908L12 19.907 15.393 18 12 16.093l1.286-2.185 3.428 1.907V12h2.607v3.815l3.393-1.907L24 16.093 20.607 18 24 19.907l-1.286 2.186-3.393-1.908V24h-2.607Z"/>
    </svg>
    """

    private static let badgeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" fill="none" viewBox="0 0 36 36">
      <path fill="#fff" d="M21.072 4a7.942 7.942 0 0 0-1.008 3H10a3 3 0 0 0-3 3v16a3 3 0 0 0 3 3h16a3 3 0 0 0 3-3V15.935a7.94 7.94 0 0 0 3-1.01V26a6 6 0 0 1-6 6H10a6 6 0 0 1-6-6V10a6 6 0 0 1 6-6h11.072Z"/>
      <path fill="#fff" d="M16.714 24v-3.815l-3.428 1.908L12 19.907 15.393 18 12 16.093l1.286-2.185 3.428 1.907V12h2.607v3.815l3.393-1.907L24 16.093 20.607 18 24 19.907l-1.286 2.186-3.393-1.908V24h-2.607Z"/>
      <circle cx="28" cy="8" r="5.5" fill="#d77757"/>
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
