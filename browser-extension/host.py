#!/usr/bin/python3
"""Chrome native messaging to the authenticated local Agent Deck service."""
import json,os,struct,sys,urllib.request

def exact(count):
 data=b''
 while len(data)<count:
  chunk=sys.stdin.buffer.read(count-len(data))
  if not chunk:return None
  data+=chunk
 return data
while True:
 header=exact(4)
 if not header:break
 length=struct.unpack('<I',header)[0]
 if length>1000000:break
 payload=exact(length)
 if payload is None:break
 try:
  endpoint=json.load(open(os.path.join(os.environ.get('AGENT_DECK_BROWSER_RUNTIME',os.path.expanduser('~/Library/Caches/AgentDeck')),'connection.json')))
  port=endpoint['port']
  if not isinstance(port,int) or not 1<=port<=65535:raise ValueError('Invalid service endpoint')
  request=urllib.request.Request('http://127.0.0.1:'+str(port)+'/browser/poll',data=payload,headers={'Authorization':'Bearer '+endpoint['token'],'Content-Type':'application/json'})
  with urllib.request.urlopen(request,timeout=5) as response:result=response.read(1000000)
 except Exception:result=json.dumps({'error':'Agent Deck service unavailable.'}).encode()
 sys.stdout.buffer.write(struct.pack('<I',len(result))+result);sys.stdout.buffer.flush()
