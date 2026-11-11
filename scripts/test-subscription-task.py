#!/usr/bin/env python3
"""No network or credentials: exercise task launch policy with fake CLIs."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'native/Resources/Jarvis/subscription-task.py'

class SubscriptionTaskTests(unittest.TestCase):
    def exercise(self, provider, connected=True, agy_task=True, config=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / 'subscription-task.py'
            wrapper.write_text(SOURCE.read_text())
            (root / 'subscription-planner.py').write_text('''import os

def sanitized_env():
    return {k:v for k,v in os.environ.items() if k in {"HOME","PATH","TMPDIR"}}

def connection_status(provider,binary=None):
    return {"state": STATE if TASK or provider != "gemini" else "unsupported", "taskSupported": TASK}
'''.replace('STATE', repr('connected' if connected else 'signInRequired')).replace('TASK', repr(agy_task)))
            if config is not None:
                settings = root / '.gemini/antigravity-cli/settings.json'
                settings.parent.mkdir(parents=True)
                settings.write_text(json.dumps(config))
            capture = root / 'capture.json'
            binary = root / 'fake-cli'
            binary.write_text('#!' + sys.executable + '\n' + '''import json,os,sys
from pathlib import Path
settings=os.environ.get('GEMINI_CLI_SYSTEM_SETTINGS_PATH')
Path(CAPTURE).write_text(json.dumps({'args':sys.argv[1:],'env':dict(os.environ),'settings':json.loads(Path(settings).read_text()) if settings else None,'stdin':sys.stdin.read()}))
print(json.dumps({'type':'result','subtype':'success','status':'success'}))
'''.replace('CAPTURE', repr(str(capture))))
            binary.chmod(0o700)
            payload = {'provider':provider,'binary':str(binary),'cwd':str(root),'prompt':'Verify tests','session':'exact-session'}
            result = subprocess.run([sys.executable,str(wrapper)], input=json.dumps(payload),text=True,capture_output=True,
                                    env={**os.environ,'OPENAI_API_KEY':'must-not-inherit','ANTHROPIC_API_KEY':'must-not-inherit','GEMINI_API_KEY':'must-not-inherit','CURSOR_API_KEY':'must-not-inherit','HOME':str(root)},timeout=5)
            return result, json.loads(capture.read_text()) if capture.exists() else None

    def test_no_signed_in_subscription_never_launches_cli(self):
        result, capture = self.exercise('claude', connected=False)
        self.assertEqual(result.returncode,2)
        self.assertIsNone(capture)
        self.assertIn('No API billing fallback',result.stdout)

    def test_all_providers_strip_api_keys_and_resume_exact_session(self):
        for provider in ('codex','claude','cursor','gemini'):
            with self.subTest(provider=provider):
                result,capture = self.exercise(provider)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('exact-session',capture['args'])
                for key in ('OPENAI_API_KEY','ANTHROPIC_API_KEY','GEMINI_API_KEY','CURSOR_API_KEY'):
                    self.assertNotIn(key,capture['env'])
                for flag in ('--force','--yolo','--dangerously-skip-permissions','--trust','--approve-mcps'):
                    self.assertNotIn(flag,capture['args'])

    def test_antigravity_blocks_unsupported_cli_and_adc_or_api_settings(self):
        for config in ({'modelProvider':'gemini'}, {'userSettings':{'enableAdc':True}}, {'gcp':{'project':'paid-project'}}):
            result,capture=self.exercise('gemini',config=config)
            self.assertEqual(result.returncode,2,result.stderr)
            self.assertIsNone(capture)
        result,capture=self.exercise('gemini',agy_task=False)
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertIsNone(capture)

    def test_antigravity_pins_account_auth_stops_credit_usage_and_keeps_permissions(self):
        result,capture=self.exercise('gemini')
        self.assertEqual(result.returncode,0,result.stderr)
        settings=json.loads(capture['args'][capture['args'].index('--settings')+1])
        self.assertEqual(settings,{'modelProvider':'','useG1Credits':False,'toolPermission':'strict','agentMode':''})
        self.assertIn('--conversation',capture['args'])
        self.assertIn('--disable-slash-commands',capture['args'])

    def test_observer_hooks_allow_only_unchanged_platform_script_without_shell_expansion(self):
        planner_path=SOURCE.with_name('subscription-planner.py')
        spec=importlib.util.spec_from_file_location('observer_policy_test', planner_path)
        planner=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(planner)
        spec=importlib.util.spec_from_file_location('task_observer_policy_test',SOURCE)
        policy=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            script=root/'observer with spaces.mjs'
            script.write_bytes((SOURCE.parents[3]/'bin/agent-hook.mjs').read_bytes())
            path=root/'hooks.json'
            command='"/opt/homebrew/bin/node" "'+str(script)+'" antigravity SessionStart'
            def save(command):
                path.write_text(json.dumps({'ai-agent-deck':{'enabled':True,'SessionStart':[{'type':'command','command':command,'timeout':5}]}}))
            save(command)
            self.assertTrue(policy.observer_hooks_safe(path))
            save(command+'; echo injected')
            self.assertFalse(policy.observer_hooks_safe(path))
            expanded=root/'$(touch never-run).mjs'
            expanded.write_bytes(script.read_bytes())
            save('"/opt/homebrew/bin/node" "'+str(expanded)+'" antigravity SessionStart')
            self.assertFalse(policy.observer_hooks_safe(path))
            for name in ['observer*.mjs', 'observer?.mjs', 'observer[ab].mjs', 'observer{a,b}.mjs', '~observer.mjs']:
                expanded=root/name
                expanded.write_bytes(script.read_bytes())
                save('/opt/homebrew/bin/node '+str(expanded)+' antigravity SessionStart')
                self.assertFalse(policy.observer_hooks_safe(path))
                self.assertFalse(planner.observer_hooks_safe(path))
            save(command)
            script.write_text('modified')
            self.assertFalse(policy.observer_hooks_safe(path))

    def test_nonreading_stdin_cannot_prevent_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            wrapper=root/'subscription-task.py'
            wrapper.write_text(SOURCE.read_text().replace('TASK_TIMEOUT_SECONDS = 1800','TASK_TIMEOUT_SECONDS = 0.2'))
            (root/'subscription-planner.py').write_text('import os\ndef sanitized_env(): return {"PATH":os.environ["PATH"]}\ndef connection_status(provider,binary=None): return {"state":"connected"}\n')
            binary=root/'fake-cli'
            binary.write_text('#!'+sys.executable+'\nimport time\ntime.sleep(60)\n')
            binary.chmod(0o700)
            result=subprocess.run([sys.executable,str(wrapper)],input=json.dumps({'provider':'claude','binary':str(binary),'cwd':str(root),'prompt':'x'*40000}),text=True,capture_output=True,timeout=3)
            self.assertEqual(result.returncode,124,result.stderr)

    def test_claude_and_codex_force_subscription_auth(self):
        _,claude=self.exercise('claude')
        self.assertIn('--safe-mode',claude['args'])
        i=claude['args'].index('--settings')
        self.assertEqual(json.loads(claude['args'][i+1])['forceLoginMethod'],'claudeai')
        self.assertEqual(claude['args'][claude['args'].index('--setting-sources')+1],'')
        _,codex=self.exercise('codex')
        self.assertIn('forced_login_method="chatgpt"',codex['args'])
        self.assertIn('--ignore-user-config',codex['args'])

if __name__=='__main__':
    unittest.main()
