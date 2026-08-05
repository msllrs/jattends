import XCTest
@testable import Jattends

final class KeepAwakeControllerTests: XCTestCase {
    private struct Harness {
        let controller: KeepAwakeController
        var passwordlessCalls: () -> [Bool]
        var promptCommands: () -> [String]
        var completePrompt: (Bool) -> Void
    }

    /// `passwordlessAvailable: false` models a machine without the sudoers
    /// rule: runPasswordless declines and the admin prompt is the fallback.
    private func makeHarness(
        pids: @escaping () -> [Int32] = { [] },
        passwordlessAvailable: Bool = false
    ) -> Harness {
        let controller = KeepAwakeController()
        var passwordless: [Bool] = []
        var prompts: [String] = []
        var promptCompletions: [(Bool) -> Void] = []
        controller.findPids = pids
        controller.runPasswordless = { start, completion in
            guard passwordlessAvailable else { return false }
            passwordless.append(start)
            completion(true)
            return true
        }
        controller.runPrivileged = { command, completion in
            prompts.append(command)
            promptCompletions.append(completion)
        }
        return Harness(
            controller: controller,
            passwordlessCalls: { passwordless },
            promptCommands: { prompts },
            completePrompt: { ok in promptCompletions.removeFirst()(ok) }
        )
    }

    // Clicking the menu row again while the first admin-password dialog is
    // still open must not launch a second instance of the script.
    func testToggleWhileAuthorizationPendingIsIgnored() {
        let h = makeHarness()
        h.controller.toggle()
        h.controller.toggle()
        XCTAssertEqual(h.promptCommands().count, 1, "second toggle during pending auth must be a no-op")
    }

    func testPasswordlessPreferredOverAdminPrompt() {
        var running: [Int32] = []
        let h = makeHarness(pids: { running }, passwordlessAvailable: true)
        var outcomes: [KeepAwakeController.Outcome] = []
        h.controller.onOutcome = { outcomes.append($0) }

        h.controller.toggle()
        running = [42]
        h.controller.toggle()

        XCTAssertEqual(h.passwordlessCalls(), [true, false], "start then stop, both passwordless")
        XCTAssertTrue(h.promptCommands().isEmpty, "admin prompt must not appear when sudo -n works")
        XCTAssertEqual(outcomes, [.started, .stopped])
    }

    func testFallsBackToAdminPromptWithoutSudoersRule() {
        var running: [Int32] = []
        let h = makeHarness(pids: { running }, passwordlessAvailable: false)
        h.controller.toggle()
        running = [42]
        h.completePrompt(true)
        h.controller.toggle()

        XCTAssertEqual(h.promptCommands().count, 2)
        XCTAssertTrue(h.promptCommands()[0].contains("awake-until-claude-idle.sh'"), "first toggle starts")
        XCTAssertEqual(h.promptCommands()[1], "kill -TERM 42", "second toggle stops the running instance")
    }

    // The outage mode that hid every failure so far: authorization succeeds
    // and the shell exits 0, but the backgrounded launch died (nohup's
    // console error did exactly this). "Started" must only be reported when
    // the script process actually exists afterwards.
    func testStartThatSilentlyDiesReportsFailed() {
        let h = makeHarness(pids: { [] })
        var outcomes: [KeepAwakeController.Outcome] = []
        h.controller.onOutcome = { outcomes.append($0) }
        h.controller.toggle()
        h.completePrompt(true)
        XCTAssertEqual(outcomes, [.failed])
    }

    func testStartThatSurvivesReportsStarted() {
        var running: [Int32] = []
        let h = makeHarness(pids: { running })
        var outcomes: [KeepAwakeController.Outcome] = []
        h.controller.onOutcome = { outcomes.append($0) }
        h.controller.toggle()
        running = [42]
        h.completePrompt(true)
        XCTAssertEqual(outcomes, [.started])
    }

    func testCancelledPromptReportsFailed() {
        let h = makeHarness()
        var outcomes: [KeepAwakeController.Outcome] = []
        h.controller.onOutcome = { outcomes.append($0) }
        h.controller.toggle()
        h.completePrompt(false)
        XCTAssertEqual(outcomes, [.failed])
    }

    // The notification's Stop action fires blind (the script may have died
    // in the meantime) — stop() must only act when something is running.
    func testStopIsNoOpWhenNotRunning() {
        let h = makeHarness(pids: { [] }, passwordlessAvailable: true)
        h.controller.stop()
        XCTAssertTrue(h.passwordlessCalls().isEmpty)
        XCTAssertTrue(h.promptCommands().isEmpty)
    }

    func testStopStopsWhenRunning() {
        let h = makeHarness(pids: { [42] }, passwordlessAvailable: true)
        var outcomes: [KeepAwakeController.Outcome] = []
        h.controller.onOutcome = { outcomes.append($0) }
        h.controller.stop()
        XCTAssertEqual(h.passwordlessCalls(), [false])
        XCTAssertEqual(outcomes, [.stopped])
    }

    func testStartCommandInjectsSudoUserAndLogs() {
        let command = KeepAwakeController.startCommand(
            scriptPath: "/Users/matt/.claude/scripts/awake-until-claude-idle.sh",
            user: "matt",
            logPath: "/Users/matt/.claude/jattends/keepawake.log"
        )
        // Without SUDO_USER the root-run script resolves ~root and sleeps
        // the Mac immediately — the env injection is load-bearing.
        XCTAssertTrue(command.contains("SUDO_USER='matt' "))
        // nohup dies with "can't detach from console" under osascript's
        // admin trampoline, silently swallowing the launch. Detaching is
        // done the TN2065 way instead: & with all three stdio redirected.
        XCTAssertFalse(command.contains("nohup"))
        XCTAssertTrue(command.contains("'/Users/matt/.claude/scripts/awake-until-claude-idle.sh'"))
        XCTAssertTrue(command.contains(">>'/Users/matt/.claude/jattends/keepawake.log' 2>&1"),
                      "lifecycle output must be kept for post-mortem diagnosis")
        XCTAssertTrue(command.contains("</dev/null"), "stdin must be detached too")
        XCTAssertTrue(command.hasSuffix("&"), "must background so osascript returns immediately")
    }

    // A substring match on the script path also hits innocent processes
    // that merely mention it (editors, agent shells, watchers) — the app
    // then shows "running" falsely and stop would TERM bystanders. The
    // pattern must anchor to the interpreter actually executing the script.
    func testProcessPatternMatchesOnlyTheInterpreterInvocation() {
        let pattern = KeepAwakeController.processPattern(
            scriptPath: "/Users/matt/.claude/scripts/awake-until-claude-idle.sh")
        XCTAssertEqual(pattern, "^/bin/zsh /Users/matt/\\.claude/scripts/awake-until-claude-idle\\.sh")

        let regex = try! NSRegularExpression(pattern: pattern)
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        XCTAssertTrue(matches("/bin/zsh /Users/matt/.claude/scripts/awake-until-claude-idle.sh"))
        XCTAssertTrue(matches("/bin/zsh /Users/matt/.claude/scripts/awake-until-claude-idle.sh 600"))
        XCTAssertFalse(matches("vim /Users/matt/.claude/scripts/awake-until-claude-idle.sh"))
        XCTAssertFalse(matches("/bin/zsh -c pgrep -f /Users/matt/.claude/scripts/awake-until-claude-idle.sh"))
        XCTAssertFalse(matches("/bin/zsh /Users/matt/Xclaude/scripts/awake-until-claude-idleYsh"))
    }

    func testStopCommandUsesTermForCleanupTrap() {
        XCTAssertEqual(KeepAwakeController.stopCommand(pids: [123]), "kill -TERM 123")
        XCTAssertEqual(KeepAwakeController.stopCommand(pids: [123, 456]), "kill -TERM 123 456")
    }
}
