import XCTest
import AppKit
@testable import Jattends

final class MenuRowViewTests: XCTestCase {
    /// Render a view offscreen and measure the vertical extent of drawn
    /// pixels (any alpha) in bitmap coordinates (row 0 = top).
    private func inkGaps(of view: NSView) -> (above: Int, below: Int)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        var minRow = Int.max
        var maxRow = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    minRow = min(minRow, y)
                    maxRow = max(maxRow, y)
                    break
                }
            }
        }
        guard minRow <= maxRow else { return nil }
        return (above: minRow, below: rep.pixelsHigh - 1 - maxRow)
    }

    private func assertVerticallyCentered(
        _ view: MenuRowView, tolerance: Int, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let gaps = inkGaps(of: view) else {
            XCTFail("\(label): no ink rendered", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            abs(gaps.above - gaps.below), tolerance,
            "\(label): ink gap above=\(gaps.above) below=\(gaps.below)",
            file: file, line: line
        )
    }

    private func singleLineRow() -> MenuRowView {
        MenuRowView(text: AppDelegate.makeMenuItemTitle(
            symbol: "○", color: .secondaryLabelColor, title: "relax", detail: nil))
    }

    func testSingleLineRowCenteredAtNaturalHeight() {
        assertVerticallyCentered(singleLineRow(), tolerance: 3, "natural height")
    }

    func testSingleLineRowCenteredWhenMenuStretchesIt() {
        // NSMenu stretches short view-backed rows to its minimum row height —
        // the regression: badge+title rows sat high/low, not centered.
        let view = singleLineRow()
        view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height + 16))
        assertVerticallyCentered(view, tolerance: 3, "stretched height")
    }

    func testTwoLineRowCenteredAtNaturalHeight() {
        let view = MenuRowView(text: AppDelegate.makeMenuItemTitle(
            symbol: "✱", color: .systemRed, title: "relax", detail: "Running: npm test"))
        assertVerticallyCentered(view, tolerance: 3, "two-line")
    }
}
