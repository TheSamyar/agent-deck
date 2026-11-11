"""Subscription-only supervised CLI tasks; never reads/copies credential tokens."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import threading

spec = importlib.util.spec_from_file_location('robin_subscription_planner', Path(__file__).with_name('subscription-planner.py'))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
child = None
TASK_TIMEOUT_SECONDS = 1800

def stop(*_):
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
        except ProcessLookupError:
            pass
    raise SystemExit(143)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

def arguments(provider, session, prompt):
    resume = ['--resume', session] if session else []
    if provider == 'codex':
        base = ['-c', 'forced_login_method="chatgpt"', '-c', 'model_provider="openai"', '--sandbox', 'workspace-write', 'exec', '--ignore-user-config']
        return base + (['resume', '--json', session, '-'] if session else ['--json', '--sandbox', 'workspace-write', '-'])
    if provider == 'claude':
        return ['--safe-mode', '--setting-sources', '', '--settings', '{"forceLoginMethod":"claudeai"}', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--print', '--verbose', '--output-format', 'stream-json'] + resume
    if provider == 'cursor':
        return ['--print', '--output-format', 'stream-json'] + resume + [prompt]
    if provider == 'gemini':
        return ['--settings', json.dumps({'modelProvider':'','useG1Credits':False,'toolPermission':'strict','agentMode':''}), '--disable-slash-commands', '--output-format', 'stream-json'] + (['--conversation', session] if session else []) + ['--print', prompt]
    raise ValueError('Unsupported task provider')

def observer_hooks_safe(path):
    if not path.exists():
        return True
    if path.stat().st_size > 100_000:
        return False
    hooks = json.loads(path.read_text())
    if not hooks:
        return True
    if not isinstance(hooks, dict) or set(hooks) != {'ai-agent-deck'}:
        return False
    group = hooks['ai-agent-deck']
    if not isinstance(group, dict):
        return False
    if group.get('enabled') is False:
        return True
    reference = Path(__file__).with_name('approved-agent-hook.mjs')
    if not reference.exists():
        reference = Path(__file__).resolve().parents[3] / 'bin/agent-hook.mjs'
    if not reference.is_file() or reference.stat().st_size > 100_000:
        return False
    digest = hashlib.sha256(reference.read_bytes()).digest()
    events = {'SessionStart', 'PreInvocation', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd'}
    if set(group) - events - {'enabled'}:
        return False
    def entry_safe(entry, event):
        if not isinstance(entry, dict):
            return False
        if 'hooks' in entry:
            return set(entry) <= {'matcher', 'hooks'} and isinstance(entry['hooks'], list) and all(entry_safe(item,event) for item in entry['hooks'])
        if set(entry) - {'type', 'command', 'timeout'} or entry.get('type') != 'command':
            return False
        command = entry.get('command', '')
        if not isinstance(command, str) or any(character in command for character in '*?[]{}~!()$`;&|<>\n\r\\'):
            return False
        parts = shlex.split(command)
        if len(parts) != 4 or parts[0] not in ('/opt/homebrew/bin/node', '/usr/local/bin/node', '/usr/bin/node') or parts[2:] != ['antigravity',event]:
            return False
        script = Path(parts[1])
        return script.is_absolute() and script.is_file() and script.stat().st_size <= 100_000 and hashlib.sha256(script.read_bytes()).digest() == digest
    return all(isinstance(entries,list) and all(entry_safe(entry,event) for entry in entries) for event,entries in group.items() if event != 'enabled')


def antigravity_configuration_safe(cwd):
    # Read configuration only, never token profiles/keyring material. Official
    # agy does not read .env and requires GEMINI_API_KEY for its API provider.
    homes = [Path.home(), Path(cwd)]
    files = [base / relative for base in homes for relative in
             ('.gemini/config/config.json', '.gemini/antigravity-cli/settings.json', '.agents/settings.json')]
    def safe(value):
        if isinstance(value, dict):
            for key, setting in value.items():
                if key in ('enableAdc', 'enableADC', 'useAdc', 'vertex') and setting not in (False, None):
                    return False
                if key in ('gcp', 'modelProvider') and setting not in ('', None, {}):
                    return False
                if key == 'auth' and isinstance(setting, dict) and setting.get('type') not in (None, 'oauth-personal'):
                    return False
                if not safe(setting):
                    return False
        elif isinstance(value, list):
            return all(safe(item) for item in value)
        return True
    for path in files:
        if path.exists():
            if path.stat().st_size > 1_000_000 or not safe(json.loads(path.read_text())):
                return False
    # Permit only the platform's unchanged localhost observer; unknown startup
    # hooks could replace auth settings between validation and inference.
    for path in (Path.home()/'.gemini/config/hooks.json', Path(cwd)/'.agents/hooks.json'):
        if not observer_hooks_safe(path):
            return False
    return True


def main():
    global child
    request = json.load(sys.stdin)
    provider = request['provider']
    binary = request['binary']
    cwd = request['cwd']
    prompt = request['prompt']
    session = request.get('session')
    if not isinstance(prompt, str) or len(prompt) > 40000 or not os.path.isdir(cwd):
        raise ValueError('Invalid task')
    if provider == 'gemini' and not antigravity_configuration_safe(cwd):
        print(json.dumps({'type':'error','message':'Antigravity account task blocked: API/ADC/Cloud/startup-hook configuration. No API fallback was started.'}), flush=True)
        return 2
    status = planner.connection_status(provider, binary=binary)
    account_task = provider == 'gemini' and os.access(binary, os.X_OK) and status.get('state') == 'connected' and status.get('taskSupported') is True
    if provider == 'gemini' and not account_task:
        print(json.dumps({'type':'error','message':'Antigravity account task blocked: unsupported CLI or API/ADC/Cloud/startup-hook configuration. No API fallback was started.'}), flush=True)
        return 2
    if status.get('state') != 'connected' and not account_task:
        print(json.dumps({'type':'error','message':'Subscription sign-in required. No API billing fallback was used.'}), flush=True)
        return 2
    env = planner.sanitized_env()
    env['AGENT_DECK_HOST_INSTANCE'] = 'supervisor-subscription'
    child = subprocess.Popen([binary] + arguments(provider, session, prompt), cwd=cwd, env=env,
                             stdin=subprocess.PIPE, start_new_session=True)
    writer_errors = []
    def write_prompt():
        try:
            if provider in ('codex', 'claude'):
                child.stdin.write(prompt.encode())
            child.stdin.close()
        except (OSError, ValueError) as error:
            writer_errors.append(error)
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    writer = threading.Thread(target=write_prompt, daemon=True)
    try:
        writer.start()
        try:
            code = child.wait(timeout=TASK_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            return 124
        writer.join(timeout=1)
        return 2 if writer_errors or writer.is_alive() else code
    finally:
        # Covers timeout, cancellation, broken stdin and every post-spawn error.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=5)
        try:
            child.stdin.close()
        except (OSError, ValueError):
            pass

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        print(json.dumps({'type':'error','message':'Subscription task could not start. Check official CLI installation and sign-in.'}), flush=True)
        sys.exit(2)
