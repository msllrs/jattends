import XCTest
@testable import Jattends

final class KeepAwakeControllerTests: XCTestCase {
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
