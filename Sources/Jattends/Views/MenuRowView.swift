import AppKit

/// Custom menu-row view so hover highlights render as a neutral rounded
/// rect instead of the accent-colored system highlight. Draws the same
/// attributed title the standard items used, forwards clicks to the
/// item's action, and shows a chevron for rows with submenus.
final class MenuRowView: NSView {
    private let text: NSAttributedString
    private let textSize: NSSize
    private let showsChevron: Bool
    private let trailing: NSAttributedString?
    private var mouseInside = false

    private static let rowWidth: CGFloat = 280
    private static let contentInsetX: CGFloat = 14
    private static let highlightInsetX: CGFloat = 5
    private static let verticalPadding: CGFloat = 5

    /// Neutral hover fill that adapts to light/dark appearance.
    private static let hoverColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(white: 0, alpha: 0.08)
    }

    /// `trailing` renders right-aligned in secondary color — used for
    /// keyboard-shortcut hints, which the system won't draw on view-backed
    /// items.
    init(text: NSAttributedString, showsChevron: Bool = false, trailing: String? = nil) {
        self.text = text
        self.showsChevron = showsChevron
        self.trailing = trailing.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        let textWidth = Self.rowWidth - Self.contentInsetX * 2 - (showsChevron ? 14 : 0)
        let measured = text.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).size
        self.textSize = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: Self.rowWidth,
            height: textSize.height + Self.verticalPadding * 2
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isRowHighlighted: Bool {
        (enclosingMenuItem?.isHighlighted ?? false) || mouseInside
    }

    override func draw(_ dirtyRect: NSRect) {
        if isRowHighlighted, enclosingMenuItem?.isEnabled != false {
            let highlightRect = bounds.insetBy(dx: Self.highlightInsetX, dy: 0)
            Self.hoverColor.setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 5, yRadius: 5).fill()
        }

        // Center on the measured text height — the menu may stretch short
        // rows to its minimum row height, and string drawing is top-anchored
        let textWidth = bounds.width - Self.contentInsetX * 2 - (showsChevron ? 14 : 0)
        text.draw(
            in: NSRect(
                x: Self.contentInsetX,
                y: (bounds.height - textSize.height) / 2,
                width: textWidth,
                height: textSize.height
            )
        )

        if showsChevron {
            let chevron = NSAttributedString(string: "›", attributes: [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = chevron.size()
            chevron.draw(at: NSPoint(
                x: bounds.width - Self.contentInsetX - size.width + 4,
                y: (bounds.height - size.height) / 2
            ))
        }

        if let trailing {
            let size = trailing.size()
            trailing.draw(at: NSPoint(
                x: bounds.width - Self.contentInsetX - size.width,
                y: (bounds.height - size.height) / 2
            ))
        }
    }

    /// Plain single-line row text in the standard menu font.
    static func plainTitle(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, item.isEnabled else { return }
        mouseInside = false
        needsDisplay = true
        item.menu?.cancelTracking()
        if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Reset hover state each time the menu (re)opens
        mouseInside = false
        needsDisplay = true
    }
}
