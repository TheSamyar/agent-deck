"""Offline billing-boundary tests. Never calls a real model or reads tokens."""
import importlib.util
import json
import os
import shlex
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("subscription_planner", ROOT / "native/Resources/Jarvis/subscription-planner.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
STEP = {"kind": "respond", "reply": "Ready", "action": None, "arguments": {}}


class SubscriptionPlannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.binary = self.root / "fake-cli"
        self.binary.write_text("#!/usr/bin/python3\nimport json,sys\nprint(json.dumps({'loggedIn':True,'authMethod':'claude.ai','apiProvider':'firstParty','subscriptionType':'max'}))\n")
        self.binary.chmod(0o700)

    def tearDown(self):
        self.temp.cleanup()

    def request(self, provider="claude"):
        return dict(provider=provider, cwd=str(self.root), output=str(self.root / "answer.json"),
                    prompt="Synthetic request", schema={"type": "object"})

    def test_environment_drops_all_auth_and_injection_paths(self):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "synthetic", "CURSOR_API_KEY": "synthetic", "GEMINI_API_KEY": "synthetic", "GOOGLE_APPLICATION_CREDENTIALS": "synthetic", "NODE_OPTIONS": "synthetic", "HTTP_PROXY": "synthetic", "GEMINI_CLI_AUTH_OVERRIDE": "api-key", "OPENAI_API_KEY": "synthetic"}):
            env = planner.sanitized_env()
            for key in ["ANTHROPIC_API_KEY", "CURSOR_API_KEY", "GEMINI_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "NODE_OPTIONS", "HTTP_PROXY", "GEMINI_CLI_AUTH_OVERRIDE", "OPENAI_API_KEY"]:
                self.assertNotIn(key, env)

    def test_official_claude_subscription_status(self):
        self.assertEqual(planner.connection_status("claude-subscription", str(self.binary))["state"], "connected")

    def test_api_key_login_is_not_subscription(self):
        self.binary.write_text("#!/usr/bin/python3\nimport json\nprint(json.dumps({'loggedIn':True,'authMethod':'api_key','apiProvider':'firstParty','subscriptionType':'max'}))\n")
        self.assertEqual(planner.connection_status("claude", str(self.binary))["state"], "signInRequired")

    def test_cursor_status_requires_browser_refresh_login(self):
        self.binary.write_text("#!/usr/bin/python3\nimport json\nprint(json.dumps({'isAuthenticated':True,'hasAccessToken':True,'hasRefreshToken':False}))\n")
        self.assertEqual(planner.connection_status("cursor", str(self.binary))["state"], "signInRequired")

    def test_successful_claude_plan_has_no_tools_or_api_fallback(self):
        event = dict(type="result", subtype="success", is_error=False, structured_output=STEP)
        def fake_run(argv, cwd, env, prompt, **kwargs):
            self.assertEqual(argv[argv.index("--tools") + 1], "")
            self.assertIn("--safe-mode", argv)
            self.assertIn('"forceLoginMethod":"claudeai"', " ".join(argv))
            return json.dumps(event).encode()
        with patch.object(planner, "discover", return_value=str(self.binary)), patch.object(planner, "run_bounded", side_effect=fake_run):
            planner.planner(self.request())
        self.assertEqual(json.loads((self.root / "answer.json").read_text()), STEP)

    def test_incomplete_and_failed_plans_rejected(self):
        for event in [dict(type="assistant", message={"content": []}), dict(type="result", subtype="error_max_turns", structured_output=STEP)]:
            with patch.object(planner, "discover", return_value=str(self.binary)), patch.object(planner, "run_bounded", return_value=json.dumps(event).encode()):
                with self.assertRaises(ValueError):
                    planner.planner(self.request())
        self.assertFalse((self.root / "answer.json").exists())

    def test_failed_gemini_partial_message_rejected(self):
        events = [dict(type="message", role="assistant", content=json.dumps(STEP)), dict(type="result", status="error")]
        with patch.object(planner, "discover", return_value=str(self.binary)), patch.object(planner, "run_bounded", return_value="\n".join(map(json.dumps, events)).encode()):
            with self.assertRaises(ValueError):
                planner.planner(self.request("gemini"))
        self.assertFalse((self.root / "answer.json").exists())

    def test_google_status_uses_zero_turn_metadata_not_inference(self):
        self.binary.write_text("#!/usr/bin/python3\nimport json,sys\nassert '/usage' in sys.argv\ns=json.loads(sys.argv[sys.argv.index('--settings')+1])\nassert s['modelProvider']=='' and s['useG1Credits'] is False\nprint(json.dumps({'status':'SUCCESS','num_turns':0,'command':{'name':'usage'}}))\n")
        with patch.object(planner, "antigravity_account_settings_safe", return_value=True):
            status = planner.connection_status("gemini-subscription", str(self.binary))
        self.assertEqual(status["state"], "connected")
        self.assertFalse(status["planningSupported"])

    def test_google_planner_is_task_only_even_with_connected_account(self):
        with patch.object(planner, "connection_status", return_value={"state": "connected", "binary": str(self.binary)}), patch.object(planner, "run_bounded") as run:
            with self.assertRaises(ValueError):
                planner.planner(self.request("gemini"))
            run.assert_not_called()

    def test_google_adc_or_api_config_blocks_subscription(self):
        folder = self.root / ".gemini/config"
        folder.mkdir(parents=True)
        for config in [{"userSettings": {"enableAdc": True}}, {"modelProvider": "gemini"}, {"gcp": {"project": "synthetic"}}, {"auth": {"type": "api-key"}}]:
            (folder / "config.json").write_text(json.dumps(config))
            with patch.object(planner.Path, "home", return_value=self.root):
                self.assertFalse(planner.antigravity_account_settings_safe())

    def test_unknown_startup_hook_blocks_google_metadata_before_launch(self):
        path = self.root / ".gemini/config/hooks.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"unknown": {"SessionStart": [{"type": "command", "command": "synthetic"}]}}))
        with patch.object(planner.Path, "home", return_value=self.root), patch.object(planner.subprocess, "run") as run:
            status = planner.connection_status("gemini", str(self.binary))
            self.assertEqual(status["state"], "unsupported")
            run.assert_not_called()

    def test_only_unchanged_platform_observer_hook_is_approved(self):
        path = self.root / "hooks.json"
        script = self.root / "agent-hook.mjs"
        script.write_bytes((ROOT / "bin/agent-hook.mjs").read_bytes())
        command = "/opt/homebrew/bin/node " + shlex.quote(str(script)) + " antigravity SessionStart"
        path.write_text(json.dumps({"ai-agent-deck": {"SessionStart": [{"type": "command", "command": command}]}}))
        self.assertTrue(planner.observer_hooks_safe(path))
        script.write_text("// synthetic changed observer\n")
        self.assertFalse(planner.observer_hooks_safe(path))

    def test_cursor_planner_fails_before_model_call(self):
        with patch.object(planner, "discover", return_value=str(self.binary)), patch.object(planner, "run_bounded") as run:
            with self.assertRaises(ValueError):
                planner.planner(self.request("cursor"))
            run.assert_not_called()

    def test_output_cannot_escape_request_directory(self):
        request = self.request()
        request["output"] = str(self.root.parent / "escaped.json")
        with patch.object(planner, "discover", return_value=str(self.binary)), patch.object(planner, "run_bounded") as run:
            with self.assertRaises(ValueError):
                planner.planner(request)
            run.assert_not_called()

    def test_unexpected_tool_stream_kills_request(self):
        self.binary.write_text("#!/usr/bin/python3\nimport json,sys,time\nsys.stdin.read()\nprint(json.dumps({'type':'assistant','message':{'content':[{'type':'tool_use','name':'Bash'}]}}),flush=True)\ntime.sleep(30)\n")
        with self.assertRaises(ValueError):
            planner.run_bounded([str(self.binary)], str(self.root), planner.sanitized_env(), "synthetic", timeout=3)

    def test_nonreading_cli_cannot_block_request_timeout(self):
        self.binary.write_text("#!/usr/bin/python3\nimport time\ntime.sleep(30)\n")
        with self.assertRaises(TimeoutError):
            planner.run_bounded([str(self.binary)], str(self.root), planner.sanitized_env(), "x" * 500_000, timeout=0.2)


if __name__ == "__main__":
    unittest.main()
