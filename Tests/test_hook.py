#!/usr/bin/env python3
"""Tests for scripts/jattends-hook.py.

Runs the hook as a subprocess against fixture events in a sandbox HOME.
No dependencies beyond the standard library:  python3 tests/test_hook.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(REPO, "scripts", "jattends-hook.py")


class HookTestCase(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="jattends-test-")
        self.env = dict(os.environ, HOME=self.home)
        self.sessions = os.path.join(self.home, ".claude", "jattends", "sessions")
        self.approvals = os.path.join(self.home, ".claude", "jattends", "approvals")

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def fire(self, event, session_id="s1", **fields):
        payload = {
            "session_id": session_id,
            "cwd": "/tmp/proj",
            "transcript_path": "/tmp/t.jsonl",
            "permission_mode": "default",
            "hook_event_name": event,
            **fields,
        }
        return subprocess.run(
            [sys.executable, HOOK], input=json.dumps(payload),
            text=True, capture_output=True, env=self.env)

    def read_session(self, session_id="s1"):
        with open(os.path.join(self.sessions, session_id + ".json")) as f:
            return json.load(f)

    def write_config(self, **config):
        os.makedirs(os.path.dirname(self.sessions), exist_ok=True)
        with open(os.path.join(self.home, ".claude", "jattends", "config.json"), "w") as f:
            json.dump(config, f)


class StatusMappingTests(HookTestCase):
    def test_session_start_is_idle(self):
        self.fire("SessionStart", source="startup")
        self.assertEqual(self.read_session()["status"], "idle")

    def test_session_start_after_compact_is_working(self):
        self.fire("SessionStart", source="compact")
        self.assertEqual(self.read_session()["status"], "working")

    def test_prompt_submit_is_working_and_captures_prompt(self):
        self.fire("UserPromptSubmit", prompt="fix the login bug\nmore detail")
        s = self.read_session()
        self.assertEqual(s["status"], "working")
        self.assertEqual(s["lastPrompt"], "fix the login bug")

    def test_post_tool_use_sets_activity_detail(self):
        self.fire("PostToolUse", tool_name="Bash", tool_input={"command": "npm test"})
        s = self.read_session()
        self.assertEqual(s["status"], "working")
        self.assertEqual(s["statusDetail"], "Running: npm test")

    def test_edit_detail_uses_basename(self):
        self.fire("PostToolUse", tool_name="Edit",
                  tool_input={"file_path": "/a/b/Store.swift"})
        self.assertEqual(self.read_session()["statusDetail"], "Editing: Store.swift")

    def test_permission_request_is_approval(self):
        self.fire("PermissionRequest", tool_name="Bash",
                  tool_input={"command": "rm -rf build"})
        s = self.read_session()
        self.assertEqual(s["status"], "approval")
        self.assertEqual(s["statusDetail"], "Running: rm -rf build")

    def test_notification_permission_prompt_is_approval(self):
        self.fire("Notification", notification_type="permission_prompt",
                  message="Claude needs your permission to use Bash")
        self.assertEqual(self.read_session()["status"], "approval")

    def test_notification_idle_prompt_is_ready_not_attention(self):
        # An idle prompt just means the session is sitting at the prompt —
        # showing it as "needs attention" nags the user about nothing.
        self.fire("Notification", notification_type="idle_prompt",
                  message="Claude is waiting for your input")
        s = self.read_session()
        self.assertEqual(s["status"], "idle")
        self.assertIsNone(s["statusDetail"])

    def test_notification_agent_needs_input_is_waiting(self):
        # Genuine questions still demand attention.
        self.fire("Notification", notification_type="agent_needs_input",
                  message="Claude is asking a question")
        self.assertEqual(self.read_session()["status"], "waiting")

    def test_notification_auth_success_writes_nothing(self):
        self.fire("Notification", notification_type="auth_success", message="ok")
        self.assertFalse(os.path.exists(os.path.join(self.sessions, "s1.json")))

    def test_stop_with_question_is_waiting(self):
        self.fire("Stop", last_assistant_message="All done.\nShould I commit?")
        s = self.read_session()
        self.assertEqual(s["status"], "waiting")
        self.assertEqual(s["statusDetail"], "Should I commit?")

    def test_stop_without_question_is_idle(self):
        self.fire("Stop", last_assistant_message="Done.")
        s = self.read_session()
        self.assertEqual(s["status"], "idle")
        self.assertIsNone(s["statusDetail"])

    def test_stop_failure_is_error(self):
        self.fire("StopFailure", matcher="rate_limit")
        s = self.read_session()
        self.assertEqual(s["status"], "error")
        self.assertEqual(s["statusDetail"], "rate_limit")

    def test_compaction_cycle(self):
        self.fire("PreCompact", matcher="auto")
        self.assertEqual(self.read_session()["status"], "compacting")
        self.fire("PostCompact", matcher="auto")
        self.assertEqual(self.read_session()["status"], "working")

    def test_session_end_deletes_file(self):
        self.fire("UserPromptSubmit", prompt="hello")
        self.fire("SessionEnd", reason="exit")
        self.assertFalse(os.path.exists(os.path.join(self.sessions, "s1.json")))

    def test_unknown_event_is_ignored(self):
        r = self.fire("SomeFutureEvent")
        self.assertEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.sessions, "s1.json")))

    def test_last_prompt_survives_later_events(self):
        self.fire("UserPromptSubmit", prompt="do the thing")
        self.fire("PostToolUse", tool_name="Read", tool_input={"file_path": "/x/y.txt"})
        self.fire("Stop", last_assistant_message="Done.")
        self.assertEqual(self.read_session()["lastPrompt"], "do the thing")

    def test_prompt_submit_stamps_turn_start(self):
        self.fire("UserPromptSubmit", prompt="go")
        started = self.read_session()["turnStartedAt"]
        self.assertTrue(started.endswith("Z"))
        self.fire("PostToolUse", tool_name="Read", tool_input={"file_path": "/x.txt"})
        self.assertEqual(self.read_session()["turnStartedAt"], started)

    def test_malformed_input_never_fails(self):
        r = subprocess.run([sys.executable, HOOK], input="not json",
                           text=True, capture_output=True, env=self.env)
        self.assertEqual(r.returncode, 0)


class DismissalTombstoneTests(HookTestCase):
    def setUp(self):
        super().setUp()
        self.dismissed = os.path.join(self.home, ".claude", "jattends", "dismissed")
        os.makedirs(self.dismissed)

    def tombstone(self, name, age=0):
        path = os.path.join(self.dismissed, name)
        open(path, "w").close()
        if age:
            past = time.time() - age
            os.utime(path, (past, past))
        return path

    def test_event_clears_tombstone_and_session_reappears(self):
        path = self.tombstone("session-s1")
        self.fire("UserPromptSubmit", prompt="back to work")
        self.assertFalse(os.path.exists(path))
        self.assertEqual(self.read_session()["status"], "working")

    def test_session_end_clears_tombstone(self):
        path = self.tombstone("session-s1")
        self.fire("SessionEnd", reason="exit")
        self.assertFalse(os.path.exists(path))

    def test_scan_prunes_dead_pid_and_stale_tombstones(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("hook", HOOK)
        hook = importlib.util.module_from_spec(spec)
        env_home = os.environ.get("HOME")
        os.environ["HOME"] = self.home
        try:
            spec.loader.exec_module(hook)
        finally:
            os.environ["HOME"] = env_home
        dead_pid = self.tombstone("pid-999999999")
        stale = self.tombstone("session-old", age=90000)
        fresh = self.tombstone("session-fresh")
        live_pid = self.tombstone("pid-12345")
        hook.prune_tombstones({12345: (1, "??", "claude")})
        self.assertFalse(os.path.exists(dead_pid))
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(fresh))
        self.assertTrue(os.path.exists(live_pid))
        self.assertTrue(hook.is_dismissed(12345))
        self.assertFalse(hook.is_dismissed(999999999))


class SubagentTrackingTests(HookTestCase):
    def subagent_dir(self, session_id="s1"):
        return os.path.join(self.home, ".claude", "jattends", "subagents", session_id)

    def test_start_and_stop_update_count(self):
        self.fire("SubagentStart", agent_id="a1", agent_type="Explore")
        self.fire("SubagentStart", agent_id="a2", agent_type="general-purpose")
        s = self.read_session()
        self.assertEqual(s["subagentCount"], 2)
        self.assertEqual(s["status"], "working")
        self.fire("SubagentStop", agent_id="a1", agent_type="Explore")
        self.assertEqual(self.read_session()["subagentCount"], 1)
        self.fire("SubagentStop", agent_id="a2", agent_type="general-purpose")
        self.assertEqual(self.read_session()["subagentCount"], 0)

    def test_duplicate_start_counts_once(self):
        self.fire("SubagentStart", agent_id="a1")
        self.fire("SubagentStart", agent_id="a1")
        self.assertEqual(self.read_session()["subagentCount"], 1)

    def test_missing_agent_id_is_ignored(self):
        r = self.fire("SubagentStart")
        self.assertEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.sessions, "s1.json")))

    def test_count_carried_on_other_events(self):
        self.fire("SubagentStart", agent_id="a1")
        self.fire("PostToolUse", tool_name="Read", tool_input={"file_path": "/x.txt"})
        self.assertEqual(self.read_session()["subagentCount"], 1)

    def test_session_end_clears_markers(self):
        self.fire("SubagentStart", agent_id="a1")
        self.assertTrue(os.path.isdir(self.subagent_dir()))
        self.fire("SessionEnd", reason="exit")
        self.assertFalse(os.path.exists(self.subagent_dir()))


class FakeJattends:
    """Make the hook believe the Jattends app is (or isn't) running,
    independent of whether the real app runs on this machine."""

    def __init__(self, env, running=True):
        self.env = env
        self.running = running

    def __enter__(self):
        self.env["JATTENDS_APP_RUNNING"] = "1" if self.running else "0"
        return self

    def __exit__(self, *exc):
        self.env.pop("JATTENDS_APP_RUNNING", None)


class ApprovalFlowTests(HookTestCase):
    def fire_permission(self):
        return self.fire("PermissionRequest", prompt_id="p1", tool_name="Bash",
                         tool_input={"command": "npm test"})

    def answer(self, behavior, delay=0.5):
        """Write a decision file once the request appears."""
        def worker():
            deadline = time.time() + 10
            while time.time() < deadline:
                requests = [f for f in os.listdir(self.approvals)
                            if f.endswith(".json") and ".decision." not in f] \
                    if os.path.isdir(self.approvals) else []
                if requests:
                    time.sleep(delay)
                    request_id = requests[0][:-len(".json")]
                    path = os.path.join(self.approvals, request_id + ".decision.json")
                    with open(path, "w") as f:
                        json.dump({"behavior": behavior}, f)
                    return
                time.sleep(0.05)
        t = threading.Thread(target=worker)
        t.start()
        return t

    def test_no_app_running_falls_through_immediately(self):
        self.write_config(inAppApprovals=True, approvalWaitSeconds=30)
        start = time.time()
        with FakeJattends(self.env, running=False):
            r = self.fire_permission()
        self.assertLess(time.time() - start, 5)
        self.assertEqual(r.stdout.strip(), "")
        self.assertEqual(self.read_session()["status"], "approval")

    def test_disabled_config_falls_through(self):
        self.write_config(inAppApprovals=False)
        with FakeJattends(self.env):
            r = self.fire_permission()
        self.assertEqual(r.stdout.strip(), "")

    def test_allow_decision_round_trip(self):
        self.write_config(inAppApprovals=True, approvalWaitSeconds=15)
        with FakeJattends(self.env):
            t = self.answer("allow")
            r = self.fire_permission()
            t.join()
        out = json.loads(r.stdout)
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "allow")
        self.assertEqual(self.read_session()["status"], "working")
        self.assertEqual(os.listdir(self.approvals), [])

    def test_deny_decision_round_trip(self):
        self.write_config(inAppApprovals=True, approvalWaitSeconds=15)
        with FakeJattends(self.env):
            t = self.answer("deny")
            r = self.fire_permission()
            t.join()
        decision = json.loads(r.stdout)["hookSpecificOutput"]["decision"]
        self.assertEqual(decision["behavior"], "deny")
        self.assertIn("reason", decision)

    def test_timeout_cleans_up_and_falls_through(self):
        self.write_config(inAppApprovals=True, approvalWaitSeconds=1)
        with FakeJattends(self.env):
            r = self.fire_permission()
        self.assertEqual(r.stdout.strip(), "")
        self.assertEqual(os.listdir(self.approvals), [])
        self.assertEqual(self.read_session()["status"], "approval")


if __name__ == "__main__":
    unittest.main(verbosity=2)
