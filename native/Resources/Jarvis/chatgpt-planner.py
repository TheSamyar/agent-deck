"""Owned Codex subscription subprocess. No credentials are read or copied here."""
import json, os, signal, subprocess, sys, threading
child = None

def stop(*_):
    if child is not None:
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
    raise SystemExit(143)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    request = json.load(sys.stdin)
    allowed = {'HOME','USER','LOGNAME','PATH','TMPDIR','LANG','LC_ALL','CODEX_HOME'}
    env = {k:v for k,v in os.environ.items() if k in allowed}
    # Fail before inference if the existing official login is not subscription-backed.
    status = subprocess.run([request['binary'],'-c','forced_login_method="chatgpt"','login','status'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if status.returncode or b'Logged in using ChatGPT' not in status.stdout + status.stderr:
        print(json.dumps({'error':'ChatGPT sign-in required. No API-key fallback was attempted.'})); sys.exit(2)
    child = subprocess.Popen([request['binary']] + request['arguments'], cwd=request['cwd'], env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    output = bytearray()
    unexpected = threading.Event()
    def read_stdout():
        while True:
            chunk=child.stdout.readline(2_000_001)
            if not chunk: break
            try:
                event=json.loads(chunk)
                item=event.get('item')
                if isinstance(item,dict) and item.get('type') not in ('agent_message','reasoning','error'):
                    unexpected.set(); os.killpg(child.pid,signal.SIGKILL); break
            except (ValueError,TypeError): pass
            output.extend(chunk)
            if len(output)>2_000_000:
                os.killpg(child.pid,signal.SIGKILL); break
    def drain_stderr():
        while child.stderr.read(4096): pass
    threads=[threading.Thread(target=read_stdout),threading.Thread(target=drain_stderr)]
    for t in threads:t.start()
    child.stdin.write(request['prompt'].encode());child.stdin.close()
    try: code=child.wait(timeout=120)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid,signal.SIGKILL);child.wait();code=124
    for t in threads:t.join(timeout=5)
    if unexpected.is_set(): print(json.dumps({"error":"Subscription planner attempted a disabled tool."}));sys.exit(3)
    if len(output)>2_000_000: print(json.dumps({'error':'Subscription response exceeded its limit.'}));sys.exit(3)
    sys.stdout.buffer.write(output)
    if code: print(json.dumps({'error':'Subscription request did not complete. Check sign-in or plan limits.'}))
    sys.exit(code)
except (KeyError,ValueError,OSError,subprocess.TimeoutExpired):
    print(json.dumps({'error':'Subscription launcher could not start. Check Codex installation and sign-in.'}));sys.exit(2)
