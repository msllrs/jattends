import XCTest
@testable import Jattends

final class BadgeDotModelTests: XCTestCase {
    func testUnchangedUrgencyIsANoOp() {
        // Regression: the dot blinked on every store reload while visible
        // because the swap decision compared freshly-created CGColor
        // instances. Re-evaluating an unchanged state must do nothing.
        XCTAssertEqual(BadgeDotModel.transition(from: .urgent, to: .urgent), .none)
        XCTAssertEqual(BadgeDotModel.transition(from: .normal, to: .normal), .none)
        XCTAssertEqual(BadgeDotModel.transition(from: nil, to: nil), .none)
    }

    func testAppearAndDisappear() {
        XCTAssertEqual(BadgeDotModel.transition(from: nil, to: .normal), .appear(.normal))
        XCTAssertEqual(BadgeDotModel.transition(from: nil, to: .urgent), .appear(.urgent))
        XCTAssertEqual(BadgeDotModel.transition(from: .normal, to: nil), .disappear)
        XCTAssertEqual(BadgeDotModel.transition(from: .urgent, to: nil), .disappear)
    }

    func testSwapOnlyOnRealUrgencyChange() {
        XCTAssertEqual(BadgeDotModel.transition(from: .normal, to: .urgent), .swap(.urgent))
        XCTAssertEqual(BadgeDotModel.transition(from: .urgent, to: .normal), .swap(.normal))
    }
}
