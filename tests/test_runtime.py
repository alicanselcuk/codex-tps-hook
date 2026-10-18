import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "usage"))
from store import insert_calls, session_samples


class InstalledRuntimeTest(unittest.TestCase):
    def setUp(self):
        prefix = os.environ.get("CODEX_THREAD_ID", "runtime")[:8]
        self.temporary = tempfile.TemporaryDirectory(prefix=prefix + "-hook-package-")
        self.directory = Path(self.temporary.name)
        self.home = self.directory / "codex home"
        self.environment = dict(os.environ, CODEX_HOME=str(self.home), CODEX_USAGE_DB="",
                                CODEX_METRICS_STATE_DB=str(self.directory / "state.sqlite3"))
        state = sqlite3.connect(self.environment["CODEX_METRICS_STATE_DB"])
        state.executescript("CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY);")
        state.close()
        self.install()
        self.hook = self.home / "hooks/codex-tps-hook/turn-metrics.ps1"
        self.database = self.hook.parent / "usage/data/usage.sqlite3"

    def tearDown(self):
        self.temporary.cleanup()

    def install(self):
        run = subprocess.run(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(ROOT / "install.ps1"),
                              "-CodexHome", str(self.home), "-PythonPath", sys.executable],
                             capture_output=True, text=True, encoding="utf-8", env=self.environment, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)

    def transcript(self, session, turn, root, *, child=False, input_tokens=1000, cached=800):
        epoch = 1790812800000
        def record(kind, milliseconds, payload):
            return dict(type=kind, timestamp=datetime.fromtimestamp((epoch + milliseconds) / 1000, timezone.utc).isoformat(), payload=payload)
        source = {"subagent": {"thread_spawn": {"parent_thread_id": "main"}}} if child else "vscode"
        records = [record("session_meta", 0, dict(id=session, source=source, cwd="synthetic-project"))]
        if child:
            records.append(record("session_meta", 0, dict(id="main", source="vscode")))
        records += [record("event_msg", 0, dict(type="task_started", turn_id=turn)),
                    record("turn_context", 0, dict(turn_id=turn, model="gpt-6.1-sol"))]
        for start, end, output, response in [(0, 3000, 100, "first"), (4000, 11000, 900, "last")]:
            records += [record("response_item", start, dict(type="message", role="user")),
                        record("event_msg", start + 2000, dict(type="item_completed", turn_id=turn,
                               item={"type": "Reasoning"}, started_at_ms=epoch + start + 1000, completed_at_ms=epoch + start + 2000)),
                        record("response_item", end, dict(type="message", role="assistant")),
                        record("token_usage_record", end + 10, dict(turn_id=turn, root_turn_id=root, thread_id=session,
                               response_id=response, usage=dict(input_tokens=input_tokens, cached_input_tokens=cached,
                               cache_write_input_tokens=50, output_tokens=output, reasoning_output_tokens=20)))]
        path = self.directory / (session + ".jsonl")
        previous = path.read_text(encoding="utf-8") + "\n" if path.exists() else ""
        path.write_text(previous + "\n".join(json.dumps(row, separators=(",", ":")) for row in records), encoding="utf-8")
        if child:
            state = sqlite3.connect(self.environment["CODEX_METRICS_STATE_DB"])
            state.execute("INSERT OR REPLACE INTO threads VALUES(?,?)", (session, str(path)))
            state.execute("INSERT OR REPLACE INTO thread_spawn_edges VALUES(?,?)", ("main", session))
            state.commit()
            state.close()
        return path

    def run_hook(self, path, turn, *, event="Stop", hide_cost=False):
        payload = dict(hook_event_name=event, turn_id=turn, transcript_path=str(path), agent_transcript_path=str(path))
        command = ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(self.hook), "-Language", "en"]
        if hide_cost:
            command.append("-HideCost")
        run = subprocess.run(command, input=json.dumps(payload), capture_output=True, text=True,
                             encoding="utf-8", env=self.environment, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(run.stderr)
        self.assertTrue(run.stdout.isascii())
        return json.loads(run.stdout)

    def test_installed_history_subagents_cache_and_replay(self):
        child = self.transcript("child", "child-turn", "first-turn", child=True, input_tokens=9000, cached=0)
        self.assertEqual(self.run_hook(child, "first-turn", event="SubagentStop"), {})
        main = self.transcript("main", "first-turn", "first-turn")
        self.transcript("main", "second-turn", "second-turn")
        message = self.run_hook(main, "second-turn")["systemMessage"]
        self.assertIn("Main session / this request · 2 calls", message)
        self.assertIn("Entire session · 2 requests · 6 calls", message)
        self.assertIn("Main session · 4 calls · Decode≈ 125.0", message)
        self.assertIn("Subagents · 2 calls · Decode≈ 125.0", message)
        self.assertIn("Session total · Input 22,000 · Output 3,000 (Reasoning 120)", message)
        self.assertIn("Session total · Cache 3,200 · Hit 14.5%", message)
        self.assertIn("Session total · Standard≈ $0.0681", message)
        self.assertNotIn("⚠", message)
        self.run_hook(main, "second-turn")
        self.assertEqual(len(session_samples(self.database, "main")), 6)
        insert_calls(self.database, [dict(session_id="unrelated", turn_id="other", response_id="other", recorded_at_ms=0)])
        self.assertEqual(len(session_samples(self.database, "main")), 6)

    def test_parent_snapshot_and_hidden_session_cost(self):
        self.transcript("child", "child-turn", "first-turn", child=True)
        main = self.transcript("main", "first-turn", "first-turn")
        message = self.run_hook(main, "first-turn", hide_cost=True)["systemMessage"]
        self.assertIn("Subagents / this request · 1 agent · 2 calls", message)
        self.assertNotIn("💵", message)
        self.assertNotIn("Standard≈", message)
        self.assertNotIn("Fast≈", message)
        self.assertEqual(len(session_samples(self.database, "main")), 4)

    def test_update_preserves_database_and_hook_ownership(self):
        main = self.transcript("main", "first-turn", "first-turn")
        self.run_hook(main, "first-turn")
        self.install()
        registration = json.loads((self.home / "hooks.json").read_text(encoding="utf-8"))
        self.assertEqual(len(registration["hooks"]["Stop"]), 1)
        self.assertEqual(len(registration["hooks"]["SubagentStop"]), 1)
        self.assertEqual(len(session_samples(self.database, "main")), 2)

    def test_index_failure_remains_visible(self):
        self.environment["CODEX_METRICS_STATE_DB"] = str(self.directory / "missing.sqlite3")
        main = self.transcript("main", "first-turn", "first-turn")
        message = self.run_hook(main, "first-turn")["systemMessage"]
        self.assertIn("Entire session", message)
        self.assertIn("Subagent session index unavailable", message)


if __name__ == "__main__":
    unittest.main()
