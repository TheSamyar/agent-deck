#!/usr/bin/env python3
"""Exercise the app's exported routing schema. No proposed action is executed."""
import argparse,json,time,urllib.request
from pathlib import Path

CASES=[('What are my agents doing?','observe'),('Check which agents need me.','observe'),('Open Cursor.','openApplication'),('Open Chrome.','openApplication'),('Read /tmp/Website/package.json in the Website project.','readFile'),('Read /tmp/AgentDeck/README.md in the Agent Deck project.','readFile'),('Delete /tmp/Downloads/old.txt in the Downloads project.','deleteFile'),("Propose sending the message 'Tests passed' to Sam in Messages.",'sendMessage'),('Propose purchasing the $10 plan on https://example.com in Chrome.','purchase'),('Stop what you are doing.','stopWork')]

def main():
 p=argparse.ArgumentParser();p.add_argument('--schema',type=Path,required=True);p.add_argument('--output',type=Path,default=Path('dist/jarvis-routing-benchmark.json'));a=p.parse_args();schema=json.loads(a.schema.read_text())
 system='You are the local Jarvis action router. Select one act step for each requested operation. Propose the requested action even when it requires confirmation: application code decides authorization and never automatically executes deletion, messages or purchases. Never claim an action executed. Applications: Cursor=com.todesktop.230313mzl4w4u92, Chrome=com.google.Chrome, Messages=com.apple.MobileSMS. Projects: Website=/tmp/Website, Agent Deck=/tmp/AgentDeck, Downloads=/tmp/Downloads. All arguments not needed are null. Use observe for agent status. Use stopWork for stop. Use respond only for nonoperational conversation.'
 results=[]
 for prompt,expected in CASES*2:
  body={'model':'qwen3.5:9b','stream':False,'think':False,'format':schema,'messages':[{'role':'system','content':system},{'role':'user','content':prompt}],'options':{'num_ctx':8192,'num_predict':500,'temperature':0}}
  r=urllib.request.Request('http://127.0.0.1:11434/api/chat',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'});start=time.monotonic()
  with urllib.request.urlopen(r,timeout=90) as response:data=json.load(response)
  step=json.loads(data['message']['content']);passed=step['kind']=='act' and step['action']==expected
  results.append({'prompt':prompt,'expected':expected,'step':step,'passed':passed,'seconds':round(time.monotonic()-start,3)})
  print(len(results),expected,passed,flush=True)
 report={'passed':sum(r['passed'] for r in results),'total':len(results),'cases':results,'actionsExecuted':0,'releaseApproved':False}
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='cases'}))
if __name__=='__main__':main()
