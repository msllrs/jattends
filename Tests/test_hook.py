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

    def test_notification_agent_needs_input_leaves_receiver_alone(self):
        # agent_needs_input announces a *background* session needing input
        # and is broadcast to every instance with the agent view open
        # (Claude Code v2.1.198+). It says nothing about the receiving
        # session — flipping the receiver to "waiting" creates one ghost
        # "needs attention" row per open task list. The task's own hooks
        # (PermissionRequest/Stop) report its status directly.
        self.fire("SessionStart", source="startup")
        self.fire("Notification", notification_type="agent_needs_input",
                  message="i wanna make… needs your input: approve Bash")
        s = self.read_session()
        self.assertEqual(s["status"], "idle")
        self.assertIsNone(s["statusDetail"])

    def test_notification_agent_needs_input_writes_nothing_untracked(self):
        # A receiver the hook has never seen shouldn't gain a record from
        # a broadcast about some other session.
        self.fire("Notification", notification_type="agent_needs_input",
                  message="i wanna make… needs your input: approve Bash")
        self.assertFalse(os.path.exists(os.path.join(self.sessions, "s1.json")))

    def test_notification_elicitation_dialog_is_waiting(self):
        # Elicitation dialogs concern the receiving session itself —
        # genuine questions still demand attention.
        self.fire("Notification", notification_type="elicitation_dialog",
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


class SessionLabelTests(HookTestCase):
    def label_path(self, session_id="s1"):
        return os.path.join(self.home, ".claude", "jattends", "labels", session_id)

    def read_label(self, session_id="s1"):
        with open(self.label_path(session_id)) as f:
            return f.read()

    def fire_statusline(self, payload):
        return subprocess.run(
            [sys.executable, HOOK, "--statusline"], input=json.dumps(payload),
            text=True, capture_output=True, env=self.env)

    def test_statusline_writes_session_name(self):
        r = self.fire_statusline({"session_id": "s1",
                                  "session_name": "fix scroll overlay gaps"})
        self.assertEqual(r.stdout, "")
        self.assertEqual(self.read_label(), "fix scroll overlay gaps")

    def test_statusline_without_name_writes_nothing(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/proj"})
        self.assertFalse(os.path.exists(self.label_path()))

    def test_statusline_keeps_existing_label_when_name_disappears(self):
        self.fire_statusline({"session_id": "s1", "session_name": "polish menu"})
        self.fire_statusline({"session_id": "s1"})
        self.assertEqual(self.read_label(), "polish menu")

    def test_statusline_falls_back_to_agent_name(self):
        self.fire_statusline({"session_id": "s1",
                              "agent": {"name": "security-reviewer"}})
        self.assertEqual(self.read_label(), "security-reviewer")

    def test_statusline_agent_name_never_clobbers_real_label(self):
        # A session moved to daemon hosting keeps refreshing without
        # session_name but with agent info — the fallback must not
        # overwrite the topic title captured earlier.
        self.fire_statusline({"session_id": "s1", "session_name": "i wanna make…"})
        self.fire_statusline({"session_id": "s1",
                              "agent": {"name": "security-reviewer"}})
        self.assertEqual(self.read_label(), "i wanna make…")

    def test_statusline_ignores_default_agent_name(self):
        # "claude" is the catch-all agent type, not a session title —
        # labeling a row "claude" hides the more informative project name.
        self.fire_statusline({"session_id": "s1", "agent": {"name": "claude"}})
        self.assertFalse(os.path.exists(self.label_path()))

    def test_statusline_normalizes_whitespace_and_truncates(self):
        self.fire_statusline({"session_id": "s1",
                              "session_name": "  a\nb   c  " + "x" * 200})
        label = self.read_label()
        self.assertTrue(label.startswith("a b c"))
        self.assertLessEqual(len(label), 120)

    def test_session_start_title_writes_label(self):
        self.fire("SessionStart", source="resume", session_title="ship the labels")
        self.assertEqual(self.read_label(), "ship the labels")

    def test_session_end_removes_label(self):
        self.fire_statusline({"session_id": "s1", "session_name": "polish menu"})
        self.fire("SessionEnd", reason="exit")
        self.assertFalse(os.path.exists(self.label_path()))

    def test_scan_prunes_only_old_orphaned_labels(self):
        self.fire_statusline({"session_id": "gone", "session_name": "old"})
        self.fire_statusline({"session_id": "fresh", "session_name": "untracked"})
        self.fire_statusline({"session_id": "s1", "session_name": "alive"})
        self.fire("SessionStart", source="startup")  # s1 has a session file
        # Orphan the labels: the app deletes session files when their
        # process dies, leaving the label behind
        os.remove(os.path.join(self.sessions, "gone.json"))
        os.remove(os.path.join(self.sessions, "fresh.json"))
        two_hours_ago = time.time() - 7200
        os.utime(self.label_path("gone"), (two_hours_ago, two_hours_ago))
        subprocess.run([sys.executable, HOOK, "--scan"],
                       text=True, capture_output=True, env=self.env)
        self.assertFalse(os.path.exists(self.label_path("gone")))
        # A recent label without a session file survives — the statusline can
        # run before the hooks have tracked its session
        self.assertEqual(self.read_label("fresh"), "untracked")
        self.assertEqual(self.read_label(), "alive")

    def test_malformed_statusline_input_never_fails(self):
        r = subprocess.run([sys.executable, HOOK, "--statusline"],
                           input="not json", text=True, capture_output=True,
                           env=self.env)
        self.assertEqual(r.returncode, 0)


class StatuslineTrackingTests(HookTestCase):
    """The bridge registers sessions hooks never see (agents-feature ptys)."""

    def fire_statusline(self, payload):
        return subprocess.run(
            [sys.executable, HOOK, "--statusline"], input=json.dumps(payload),
            text=True, capture_output=True, env=self.env)

    def write_transcript(self, entries):
        path = os.path.join(self.home, "transcript.jsonl")
        with open(path, "w") as f:
            for entry in entries:
                f.write(json.dumps(entry) + "\n")
        return path

    def age_session(self, session_id="s1", seconds=10):
        path = os.path.join(self.sessions, session_id + ".json")
        past = time.time() - seconds
        os.utime(path, (past, past))

    def test_registers_untracked_session(self):
        transcript = self.write_transcript([
            {"type": "user", "isMeta": True,
             "message": {"content": "<command-name>ignored</command-name>"}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "content": "ignored"}]}},
            {"type": "user", "message": {"content": "polish the beta badge\nmore"}},
        ])
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt",
                              "transcript_path": transcript})
        s = self.read_session()
        self.assertEqual(s["status"], "working")
        self.assertEqual(s["trackedBy"], "statusline")
        self.assertEqual(s["cwd"], "/tmp/wt")
        self.assertEqual(s["lastPrompt"], "polish the beta badge")

    def test_never_touches_hook_owned_sessions(self):
        self.fire("SessionStart", source="startup")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/other"})
        s = self.read_session()
        self.assertEqual(s["status"], "idle")
        self.assertNotIn("trackedBy", s)
        self.assertEqual(s["cwd"], "/tmp/proj")

    def test_hook_event_takes_ownership(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.fire("UserPromptSubmit", prompt="now via hooks")
        s = self.read_session()
        self.assertNotIn("trackedBy", s)
        self.assertEqual(s["status"], "working")
        # ...and the bridge stays hands-off afterwards
        self.age_session()
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/elsewhere"})
        self.assertEqual(self.read_session()["cwd"], "/tmp/proj")

    def test_rewrites_are_throttled(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/changed"})
        self.assertEqual(self.read_session()["cwd"], "/tmp/wt")
        self.age_session()
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/changed"})
        self.assertEqual(self.read_session()["cwd"], "/tmp/changed")

    def test_tty_for_pid_is_none_without_a_tty(self):
        # A process whose stdio is all pipes has no pty to discover
        proc = subprocess.Popen(["sleep", "5"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out = subprocess.run(
                [sys.executable, "-c",
                 "import importlib.util, sys\n"
                 "spec = importlib.util.spec_from_file_location('h', %r)\n"
                 "h = importlib.util.module_from_spec(spec)\n"
                 "spec.loader.exec_module(h)\n"
                 "print(h.tty_for_pid(%d))" % (HOOK, proc.pid)],
                text=True, capture_output=True, env=self.env)
            self.assertEqual(out.stdout.strip(), "None")
        finally:
            proc.kill()

    def test_respects_dismissal_tombstone(self):
        dismissed = os.path.join(self.home, ".claude", "jattends", "dismissed")
        os.makedirs(dismissed, exist_ok=True)
        open(os.path.join(dismissed, "session-s1"), "w").close()
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertFalse(
            os.path.exists(os.path.join(self.sessions, "s1.json")))


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

    def test_request_carries_session_label(self):
        self.write_config(inAppApprovals=True, approvalWaitSeconds=15)
        subprocess.run(
            [sys.executable, HOOK, "--statusline"],
            input=json.dumps({"session_id": "s1", "session_name": "polish menu"}),
            text=True, capture_output=True, env=self.env)
        captured = {}

        def capture_then_allow():
            def worker():
                deadline = time.time() + 10
                while time.time() < deadline:
                    requests = [f for f in os.listdir(self.approvals)
                                if f.endswith(".json") and ".decision." not in f] \
                        if os.path.isdir(self.approvals) else []
                    if requests:
                        with open(os.path.join(self.approvals, requests[0])) as f:
                            captured.update(json.load(f))
                        path = os.path.join(
                            self.approvals,
                            requests[0][:-len(".json")] + ".decision.json")
                        with open(path, "w") as f:
                            json.dump({"behavior": "allow"}, f)
                        return
                    time.sleep(0.05)
            t = threading.Thread(target=worker)
            t.start()
            return t

        with FakeJattends(self.env):
            t = capture_then_allow()
            self.fire_permission()
            t.join()
        self.assertEqual(captured.get("sessionName"), "polish menu")

    def test_timeout_cleans_up_and_falls_through(self):
        self.write_config(inAppApprovals=True, approvalWaitSeconds=1)
        with FakeJattends(self.env):
            r = self.fire_permission()
        self.assertEqual(r.stdout.strip(), "")
        self.assertEqual(os.listdir(self.approvals), [])
        self.assertEqual(self.read_session()["status"], "approval")


class ClaudeSessionRecordTests(HookTestCase):
    """The hook consults Claude Code's own per-process session records
    (~/.claude/sessions/<pid>.json) for session kind (bg vs interactive),
    true busy/idle status, and background task titles."""

    def fire_statusline(self, payload):
        return subprocess.run(
            [sys.executable, HOOK, "--statusline"], input=json.dumps(payload),
            text=True, capture_output=True, env=self.env)

    def write_claude_record(self, pid=4242, **fields):
        d = os.path.join(self.home, ".claude", "sessions")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "%d.json" % pid), "w") as f:
            json.dump(fields, f)

    def read_label(self, session_id="s1"):
        try:
            path = os.path.join(self.home, ".claude", "jattends",
                                "labels", session_id)
            with open(path) as f:
                return f.read()
        except OSError:
            return None

    def age_session(self, session_id="s1", seconds=10):
        path = os.path.join(self.sessions, session_id + ".json")
        past = time.time() - seconds
        os.utime(path, (past, past))

    # --- Bridge status follows the record's busy/idle ---

    def test_idle_record_registers_as_idle(self):
        self.write_claude_record(sessionId="s1", kind="bg", status="idle")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        s = self.read_session()
        self.assertEqual(s["status"], "idle")
        self.assertEqual(s["kind"], "bg")
        self.assertEqual(s["trackedBy"], "statusline")

    def test_busy_record_registers_as_working(self):
        self.write_claude_record(sessionId="s1", kind="bg", status="busy")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertEqual(self.read_session()["status"], "working")

    def test_missing_record_defaults_to_working_without_kind(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        s = self.read_session()
        self.assertEqual(s["status"], "working")
        self.assertNotIn("kind", s)

    def test_record_for_another_session_is_ignored(self):
        self.write_claude_record(sessionId="other", kind="bg", status="idle")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        s = self.read_session()
        self.assertEqual(s["status"], "working")
        self.assertNotIn("kind", s)

    def test_status_follows_record_across_refreshes(self):
        self.write_claude_record(sessionId="s1", kind="bg", status="busy")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertEqual(self.read_session()["status"], "working")
        self.write_claude_record(sessionId="s1", kind="bg", status="idle")
        self.age_session()
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertEqual(self.read_session()["status"], "idle")

    # --- Background task titles become labels ---

    def test_bg_task_title_becomes_label(self):
        self.write_claude_record(sessionId="s1", kind="bg", status="idle",
                                 name="pr review #46498")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertEqual(self.read_label(), "pr review #46498")

    def test_unnamed_bg_short_id_is_not_a_label(self):
        # Unnamed bg sessions carry the session id's first 8 chars as name
        self.write_claude_record(sessionId="abcd1234-5678", kind="bg",
                                 status="idle", name="abcd1234")
        self.fire_statusline({"session_id": "abcd1234-5678", "cwd": "/tmp/wt"})
        self.assertIsNone(self.read_label("abcd1234-5678"))

    def test_session_name_wins_over_task_title(self):
        self.write_claude_record(sessionId="s1", kind="bg", status="idle",
                                 name="task title")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt",
                              "session_name": "topic title"})
        self.assertEqual(self.read_label(), "topic title")

    def test_existing_label_is_not_clobbered_by_task_title(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt",
                              "session_name": "topic title"})
        self.write_claude_record(sessionId="s1", kind="bg", status="idle",
                                 name="task title")
        self.age_session()
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertEqual(self.read_label(), "topic title")

    def test_interactive_record_name_is_not_a_label(self):
        # Interactive sessions get slug names like "lovable-7b" — their real
        # titles arrive via session_name, never the record
        self.write_claude_record(sessionId="s1", kind="interactive",
                                 status="idle", name="lovable-7b")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertIsNone(self.read_label())
        self.assertEqual(self.read_session()["kind"], "interactive")

    def test_hook_owned_bg_session_still_gets_title_label(self):
        # Hooks own the record, but the statusline bridge still writes labels
        self.fire("SessionStart", source="startup")
        self.write_claude_record(sessionId="s1", kind="bg", status="idle",
                                 name="task title")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertEqual(self.read_label(), "task title")
        s = self.read_session()
        self.assertNotIn("trackedBy", s)
        self.assertEqual(s["cwd"], "/tmp/proj")

    # --- Hook events stamp kind but keep their own status ---

    def test_hook_event_stamps_bg_kind(self):
        self.write_claude_record(sessionId="s1", kind="bg", status="idle")
        self.fire("UserPromptSubmit", prompt="go")
        s = self.read_session()
        self.assertEqual(s["kind"], "bg")
        self.assertEqual(s["status"], "working")  # event wins over record

    def test_hook_event_without_record_leaves_kind_unset(self):
        self.fire("UserPromptSubmit", prompt="go")
        self.assertNotIn("kind", self.read_session())

    # --- Scan heals fossil bridge records ---
    # Idle daemon sessions stop re-rendering their statusline, so a bridge
    # record can be stuck at its last written status forever. The periodic
    # --scan reconciles statusline-tracked records against Claude Code's
    # session records so they don't need a refresh to heal.

    def scan(self):
        return subprocess.run([sys.executable, HOOK, "--scan"],
                              text=True, capture_output=True, env=self.env)

    def test_scan_heals_stuck_statusline_sessions(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.assertEqual(self.read_session()["status"], "working")
        self.write_claude_record(sessionId="s1", kind="bg", status="idle")
        self.scan()
        s = self.read_session()
        self.assertEqual(s["status"], "idle")
        self.assertEqual(s["kind"], "bg")

    def test_scan_marks_busy_statusline_sessions_working(self):
        self.write_claude_record(sessionId="s1", kind="bg", status="idle")
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.write_claude_record(sessionId="s1", kind="bg", status="busy")
        self.scan()
        self.assertEqual(self.read_session()["status"], "working")

    def test_scan_labels_stuck_bg_sessions(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        self.write_claude_record(sessionId="s1", kind="bg", status="idle",
                                 name="pr review #46498")
        self.scan()
        self.assertEqual(self.read_label(), "pr review #46498")

    def test_scan_never_touches_hook_owned_sessions(self):
        self.fire("UserPromptSubmit", prompt="go")
        self.write_claude_record(sessionId="s1", kind="bg", status="idle")
        self.scan()
        s = self.read_session()
        self.assertEqual(s["status"], "working")
        self.assertNotIn("kind", s)

    def test_scan_leaves_statusline_sessions_without_record_alone(self):
        self.fire_statusline({"session_id": "s1", "cwd": "/tmp/wt"})
        before = self.read_session()
        self.scan()
        self.assertEqual(self.read_session(), before)

    # --- Viewer terminals ---
    # A terminal claude holding a connection to a background-task daemon's
    # control.sock is a viewer: it's displaying the task list or an attached
    # task, both already represented by named rows. Scan stamps `viewer` so
    # readers can hide the bare host row. JATTENDS_VIEWER_PIDS overrides the
    # lsof probe for tests (comma-separated pids; empty = none).

    def write_session(self, session_id="s1", **fields):
        os.makedirs(self.sessions, exist_ok=True)
        session = {"sessionId": session_id, "cwd": "/tmp/proj",
                   "status": "idle", "updatedAt": "2026-07-24T00:00:00Z"}
        session.update(fields)
        with open(os.path.join(self.sessions, session_id + ".json"), "w") as f:
            json.dump(session, f)

    def scan_with_viewers(self, pids):
        env = dict(self.env, JATTENDS_VIEWER_PIDS=pids)
        return subprocess.run([sys.executable, HOOK, "--scan"],
                              text=True, capture_output=True, env=env)

    def test_scan_marks_idle_viewer_terminals(self):
        self.write_session(claudePid=4242, trackedBy="statusline")
        self.scan_with_viewers("4242")
        self.assertIs(self.read_session()["viewer"], True)

    def test_scan_clears_viewer_once_detached(self):
        self.write_session(claudePid=4242, trackedBy="statusline", viewer=True)
        self.scan_with_viewers("")
        self.assertNotIn("viewer", self.read_session())

    def test_scan_viewer_stamp_waits_for_quiet_hook_owned_files(self):
        self.write_session(claudePid=4242)  # hook-owned: no trackedBy
        self.scan_with_viewers("4242")
        self.assertNotIn("viewer", self.read_session())  # fresh — hands off
        self.age_session(seconds=120)
        self.scan_with_viewers("4242")
        self.assertIs(self.read_session()["viewer"], True)

    def test_scan_backfills_kind_on_quiet_hook_owned_sessions(self):
        # A finished bg task may never fire another hook event to stamp its
        # kind — scan backfills it once the file has been quiet long enough
        # that racing a live hook write is effectively impossible.
        self.fire("UserPromptSubmit", prompt="go")
        self.write_claude_record(sessionId="s1", kind="bg", status="idle")
        self.age_session(seconds=120)
        self.scan()
        s = self.read_session()
        self.assertEqual(s["kind"], "bg")
        self.assertEqual(s["status"], "working")  # never status, only kind
        self.assertNotIn("trackedBy", s)


class RexTests(HookTestCase):
    """Rex is a multiplexer: claude's parent is the rex server daemon, not a
    GUI app, so the pane can only be found by the block ID Rex exports."""

    REX_ENV = {
        "TERM_PROGRAM": "rex",
        "REX_BLOCK": "block:01a17930-e285-72f1-af70-533882e2596c",
        "REX_SESSION": "session:01a17930-e285-7071-9c29-96dbb57b5fff",
        "REX_BIN_DIR": "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.app/Contents/MacOS",
    }

    def test_records_rex_block_and_session(self):
        self.env.update(self.REX_ENV)
        self.fire("UserPromptSubmit", prompt="go")
        s = self.read_session()
        self.assertEqual(s["rexBlock"], self.REX_ENV["REX_BLOCK"])
        self.assertEqual(s["rexSession"], self.REX_ENV["REX_SESSION"])
        self.assertEqual(s["rexBinDir"], self.REX_ENV["REX_BIN_DIR"])

    def test_no_rex_fields_outside_rex(self):
        for k in ("REX_BLOCK", "REX_SESSION", "REX_BIN_DIR"):
            self.env.pop(k, None)
        self.fire("UserPromptSubmit", prompt="go")
        s = self.read_session()
        self.assertNotIn("rexBlock", s)
        self.assertNotIn("rexSession", s)


if __name__ == "__main__":
    unittest.main(verbosity=2)
