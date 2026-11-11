#!/usr/bin/python3
"""Run one pre-approved argv in its own process group; never use a shell."""
import json,os,signal,subprocess,sys
command=json.loads(sys.argv[1])
if not isinstance(command,list) or not command or not all(isinstance(x,str) for x in command) or not os.path.isabs(command[0]):
 raise SystemExit('Invalid approved command')
try:
 os.setsid()
except PermissionError:
 # Foundation Process on macOS may already create a dedicated process group.
 # Never install killpg handling unless this process owns that group.
 if os.getpgrp()!=os.getpid():
  raise
def stop(*_):
 os.killpg(os.getpgrp(),signal.SIGKILL)
signal.signal(signal.SIGTERM,stop)
try:
 result=subprocess.run(command,timeout=120,check=False)
 sys.exit(result.returncode)
except subprocess.TimeoutExpired:
 print('Project command exceeded 120 seconds.',file=sys.stderr,flush=True)
 stop()
