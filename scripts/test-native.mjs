#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, readFile, mkdir, writeFile, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
const root = path.resolve(import.meta.dirname, '..');
const bin = path.join(root, 'native/.build/debug');
for (const script of ['test-subscription-planner.py', 'test-subscription-task.py', 'test-personal-oauth.py']) {
  execFileSync('/usr/bin/python3', [path.join(root, 'scripts', script)], { stdio: 'inherit' });
}
const temp = await mkdtemp(path.join(os.tmpdir(), 'deck-e2e-'));
const runtime = path.join(temp, 'run');
const probe = net.createServer(); await new Promise(r => probe.listen(0, '127.0.0.1', r)); const port = probe.address().port; await new Promise(r => probe.close(r));
const mockCodex=path.join(temp,'mock-codex.cjs');
await writeFile(mockCodex,`#!/usr/bin/env node
const rl=require('node:readline').createInterface({input:process.stdin});
const send=value=>process.stdout.write(JSON.stringify(value)+'\\n');
let delivered=0;setInterval(()=>{try{const events=JSON.parse(require('node:fs').readFileSync(${JSON.stringify(path.join(temp,'work-events.json'))},'utf8'));while(delivered<events.length)send(events[delivered++]);}catch{}},10);
rl.on('line',line=>{const m=JSON.parse(line);if(m.method==='initialize')send({id:m.id,result:{}});else if(m.method==='account/read')send({id:m.id,result:{account:{type:'chatgpt'}}});else if(m.method==='thread/start')send({id:m.id,result:{modelProvider:'openai',thread:{id:'thread-test'}}});else if(m.method==='turn/start'){send({id:m.id,result:{turn:{id:'turn-test'}}});send({method:'turn/started',params:{threadId:'thread-test',turn:{id:'turn-test'}}});send({id:'approval-test',method:'item/commandExecution/requestApproval',params:{threadId:'thread-test',turnId:'turn-test',command:'printf harmless'}});}else if(m.id==='approval-test'){require('node:fs').writeFileSync(${JSON.stringify(path.join(temp,'codex-decision.json'))},JSON.stringify(m));send({method:'serverRequest/resolved',params:{threadId:'thread-test',requestId:'approval-test'}});send({method:'turn/completed',params:{threadId:'thread-test'}});}});
`,{mode:0o700});
const env = { ...process.env, AGENT_DECK_CODEX_BINARY: mockCodex, AGENT_DECK_RUNTIME: runtime, AGENT_DECK_SUPPORT: path.join(temp, 'data'), AGENT_DECK_PORT: String(port), AGENT_DECK_DISABLE_SCAN: '1' };
const service = spawn(path.join(bin, 'deck-service'), [], { env, stdio: ['ignore', 'pipe', 'pipe'] });
let logs = ''; service.stdout.on('data', c => logs += c); service.stderr.on('data', c => logs += c);
const hooks = [];
try {
  let endpoint;
  for(let i=0;i<100;i++){ try { endpoint=JSON.parse(await readFile(path.join(runtime,'connection.json'),'utf8'));break; } catch { await delay(50); } }
  assert(endpoint, 'Native service did not start: '+logs);
  const base = `http://127.0.0.1:${port}`;
  const headers = {Authorization:`Bearer ${endpoint.token}`, 'Content-Type':'application/json'};
  const get = async () => (await fetch(base+'/status',{headers})).json();
  const action = async value => (await fetch(base+'/action',{method:'POST',headers,body:JSON.stringify({id:crypto.randomUUID(),action:'respond',sessionId:'',requestId:'',choiceId:'',heldMs:0,...value})})).json();
  assert.equal((await fetch(base+'/status')).status,401);
  assert.equal((await fetch(base+'/health')).status,401);
  const health = await (await fetch(base+'/health',{headers})).json();
  assert.equal(typeof health.accessibilityGranted,'boolean');
  assert.equal((await fetch(base+'/health',{headers:{...headers,Origin:'https://example.com'}})).status,403);
  assert.equal((await fetch(base+'/status',{headers:{...headers,Origin:'https://example.com'}})).status,403);
  assert.equal((await stat(path.join(runtime,'deck.sock'))).mode & 0o777,0o600);
  function hook(session,extra={}) {
    const child=spawn(path.join(bin,'deck-hook'),['claude','PermissionRequest'],{env,stdio:['pipe','pipe','pipe']});hooks.push(child);let output='';child.stdout.on('data',c=>output+=c);child.stdin.end(JSON.stringify({session_id:session,cwd:'/test/shared-project',tool_name:'Bash',tool_input:{command:'printf harmless'},...extra}));return {child,output:()=>output,done:new Promise(r=>child.on('exit',r))};
  }
  const first=hook('first'),second=hook('second');
  let snapshot;
  for(let i=0;i<100;i++){snapshot=await get();if(snapshot.requests.length===2)break;await delay(20);}
  const childPermission=hook('first',{agent_id:'subagent-fixture'});await childPermission.done;
  assert.deepEqual(JSON.parse(childPermission.output()),{},'Subagent hook must leave permission handling to the original agent');
  execFileSync(path.join(bin,'deck-hook'),['claude','SubagentStop',JSON.stringify({session_id:'first',agent_id:'subagent-fixture',cwd:'/test/shared-project'})],{env,stdio:'pipe'});
  snapshot=await get();assert.equal(snapshot.requests.length,2);assert.equal(snapshot.sessionCount,2);
  const stale=await (await fetch(base+'/press/deny',{method:'POST',headers,body:JSON.stringify({revision:snapshot.revision,instanceId:'previous-service',commandId:crypto.randomUUID()})})).json();
  assert.equal(stale.ok,false);assert(stale.message.includes('layout changed'));
  assert.equal(snapshot.sessionCount,2);assert.equal(snapshot.requests.length,2);
  const a=snapshot.requests.find(r=>snapshot.sessions[r.sessionId].providerSessionId==='first');
  const b=snapshot.requests.find(r=>r.id!==a.id);
  const turn = async body => fetch(base+'/masterhub/turn',{method:'POST',headers,body:JSON.stringify(body)});
  assert.equal((await turn({instanceId:'old-instance',delta:1})).status,409);
  assert.equal((await turn({instanceId:snapshot.instanceId,delta:1001})).status,409);
  assert.equal((await turn({instanceId:snapshot.instanceId,delta:1,fromSessionId:'missing-session'})).status,409);
  const turnedResponse=await turn({instanceId:snapshot.instanceId,delta:1});
  assert.equal(turnedResponse.status,200);
  const turned=await turnedResponse.json();
  assert(turned.stateVersion>snapshot.stateVersion,'Dial selection must advance source version');
  assert(Object.hasOwn(turned.sessions,turned.selectedSessionId),'Dial must select an existing session');
  // Mac focus is executed by the authenticated GUI, never by the background helper.
  assert.equal((await fetch(base+'/gui/control',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status,401);
  const gui = async (clientID,replies=[]) => fetch(base+'/gui/control',{method:'POST',headers,
    body:JSON.stringify({clientID,accessibilityGranted:true,replies})});
  assert.equal((await gui('test-gui')).status,200);
  assert.equal((await gui('other-gui')).status,409);
  const readyHealth=await (await fetch(base+'/health',{headers})).json();
  assert.equal(readyHealth.controlHost,'app');assert.equal(readyHealth.accessibilityGranted,true);
  const focusing=action({action:'focus',sessionId:a.sessionId});
  let focusRequest;
  for(let i=0;i<50;i++){
    const delivery=await (await gui('test-gui')).json();
    focusRequest=delivery.requests.find(r=>r.kind==='focus');
    if(focusRequest)break;await delay(20);
  }
  assert(focusRequest,'Focus was not delivered to the GUI');
  assert.equal(focusRequest.session.id,a.sessionId);
  await gui('test-gui',[{id:focusRequest.id,result:{ok:true,state:'acknowledged',message:'Mock GUI focus',commandId:''}}]);
  assert.equal((await focusing).message,'Mock GUI focus');
  assert.equal((await action({sessionId:b.sessionId,requestId:a.id,choiceId:'allow',heldMs:700})).ok,false);
  assert.equal((await action({sessionId:a.sessionId,requestId:a.id,choiceId:'allow',heldMs:0})).ok,false);
  const accepted=await action({sessionId:a.sessionId,requestId:a.id,choiceId:'allow',heldMs:700});assert.equal(accepted.state,'submitted');
  await first.done;assert.equal(JSON.parse(first.output()).hookSpecificOutput.decision.behavior,'allow');
  assert.equal((await action({sessionId:a.sessionId,requestId:a.id,choiceId:'allow',heldMs:700})).ok,false);
  second.child.kill('SIGTERM');await second.done;
  for(let i=0;i<40;i++){snapshot=await get();if(!snapshot.requests.some(r=>r.id===b.id))break;await delay(25);}
  assert(!snapshot.requests.some(r=>r.id===b.id),'Cancelled hook remained actionable');
  const sendHook = (event,body) => new Promise((resolve,reject)=>{
    const payload=JSON.stringify(body);
    const request=http.request({socketPath:path.join(runtime,'deck.sock'),path:'/hook/claude/'+event,method:'POST',headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(payload)}},response=>{
      let text='';response.on('data',chunk=>text+=chunk);response.on('end',()=>resolve(JSON.parse(text)));
    });request.on('error',reject);request.end(payload);
  });
  const reused={data:{session_id:'reused-pid-fixture',cwd:'/test/reused-owner'},env:{ppid:process.pid,processBirth:'different-process-incarnation',bundleId:'com.apple.Terminal',tty:'/dev/ttys999'}};
  await sendHook('UserPromptSubmit',reused);
  snapshot=await get();const reusedSession=Object.values(snapshot.sessions).find(s=>s.providerSessionId==='reused-pid-fixture');assert(reusedSession);
  const staleOwner=await action({action:'focus',sessionId:reusedSession.id});assert.equal(staleOwner.ok,false);assert(staleOwner.message.includes('original agent process has ended'));
  assert.equal((await get()).sessions[reusedSession.id].status,'DISCONNECTED');
  await sendHook('SessionEnd',reused);
  const started=await (await fetch(base+'/codex/start',{method:'POST',headers,body:JSON.stringify({cwd:temp,prompt:'A harmless mocked task'})})).json();
  assert.equal(started.ok,true,started.message);
  let codexRequest;
  for(let i=0;i<100;i++){snapshot=await get();codexRequest=snapshot.requests.find(r=>r.source==='codex-app-server');if(codexRequest)break;await delay(20);}
  assert(codexRequest,'Managed Codex approval did not appear');
  assert.equal((await action({sessionId:codexRequest.sessionId,requestId:codexRequest.id,choiceId:'allow',heldMs:700})).ok,true);
  let rpc;
  for(let i=0;i<50;i++){try{rpc=JSON.parse(await readFile(path.join(temp,'codex-decision.json'),'utf8'));break;}catch{await delay(20);}}
  assert.equal(rpc.id,'approval-test');assert.equal(rpc.result.decision,'accept');
  // Drive actual app-server notifications; never start a real agent or command.
  const workEvents=[];
  const emitWork=async(method,params)=>{workEvents.push({method,params:{threadId:'thread-test',...params}});await writeFile(path.join(temp,'work-events.json'),JSON.stringify(workEvents));};
  const expectWork=async(predicate,message)=>{let value;for(let i=0;i<100;i++){value=(await get()).sessions[codexRequest.sessionId];if(predicate(value))return value;await delay(20);}assert.fail(message+': '+JSON.stringify({status:value?.status,work:value?.work}));};
  await expectWork(s=>s?.status==='DONE','Initial root did not finish');
  await emitWork('turn/started',{turn:{id:'work-turn'}});
  await emitWork('item/started',{turnId:'work-turn',item:{id:'shell-fixture',type:'commandExecution',status:'inProgress'}});
  await expectWork(s=>s?.work?.shellJobs===1,'Shell was not tracked');
  await emitWork('turn/completed',{turn:{id:'work-turn'}});
  await expectWork(s=>s?.status==='WORKING'&&s.work?.awaitingResults,'Root finished while shell was running');
  await emitWork('item/completed',{turnId:'work-turn',item:{id:'shell-fixture',type:'commandExecution',status:'completed'}});
  await expectWork(s=>s?.status==='WORKING'&&s.work?.shellJobs===0,'Shell completion incorrectly finished root');
  await emitWork('item/completed',{item:{id:'spawn-fixture',type:'collabAgentToolCall',tool:'spawnAgent',status:'completed',receiverThreadIds:['child-fixture'],agentsStates:{'child-fixture':{status:'running'}}}});
  await expectWork(s=>s?.status==='WORKING'&&s.work?.subagents===1,'Running child was not aggregated');
  assert(!Object.values((await get()).sessions).some(s=>s.providerSessionId==='child-fixture'),'Child became a root tile');
  await emitWork('turn/completed',{turn:{id:'work-turn'}});
  await expectWork(s=>s?.status==='WORKING'&&s.work?.subagents===1,'Root finished while child was running');
  await emitWork('turn/completed',{threadId:'child-fixture',turn:{id:'child-turn'}});
  await expectWork(s=>s?.status==='WORKING'&&s.work?.subagents===0,'Child completion incorrectly finished root');
  await emitWork('turn/completed',{turn:{id:'work-turn'}});
  await expectWork(s=>s?.status==='DONE','Final root completion did not finish');

  const ptyScript=path.join(temp,'foreground.py'),signalFile=path.join(temp,'interrupt.json');
  await writeFile(ptyScript,`import os,pty,fcntl,termios,signal,sys,json,subprocess
master,slave=pty.openpty()
fcntl.ioctl(slave,termios.TIOCSCTTY,0)
os.tcsetpgrp(slave,os.getpgrp())
def interrupted(signum,frame):
 with open(sys.argv[3],'w') as f: json.dump({'signal':signum},f)
 sys.exit(0)
signal.signal(signal.SIGINT,interrupted)
env=dict(os.environ,TTY=os.ttyname(slave),__CFBundleIdentifier='com.apple.Terminal')
subprocess.run([sys.argv[1],'claude','UserPromptSubmit'],input=json.dumps({'session_id':sys.argv[2],'cwd':'/test/disposable-interrupt'}).encode(),env=env,check=True)
print(json.dumps({'ready':True}),flush=True)
signal.alarm(20)
while True: signal.pause()
`);
  const foreground=spawn('/usr/bin/python3',[ptyScript,path.join(bin,'deck-hook'),'interrupt-fixture',signalFile],{env,detached:true,stdio:['ignore','pipe','pipe']});hooks.push(foreground);
  let foregroundError='';foreground.stderr.on('data',c=>foregroundError+=c);
  let ready='';foreground.stdout.on('data',c=>ready+=c);const foregroundDone=new Promise(r=>foreground.once('exit',r));
  for(let i=0;i<500&&!ready.includes('ready');i++)await delay(20);assert(ready.includes('ready'),'Disposable foreground terminal was not ready: '+foregroundError);
  snapshot=await get();const target=Object.values(snapshot.sessions).find(s=>s.providerSessionId==='interrupt-fixture');assert(target,'Disposable terminal session was not registered');
  assert.equal((await action({action:'stop',sessionId:target.id,heldMs:0})).ok,false);
  const stopped=await action({action:'stop',sessionId:target.id,heldMs:700});if(!stopped.ok){console.error('Foreground fixture',JSON.stringify(target));console.error(execFileSync('/bin/ps',['-p',String(target.pid),'-o','pid=,ppid=,pgid=,tty=,comm='],{encoding:'utf8'}));try{console.error(execFileSync('/usr/bin/python3',['-c','import os,sys; f=os.open(sys.argv[1],os.O_RDONLY|os.O_NOCTTY|os.O_NONBLOCK); print("group",os.getpgid(int(sys.argv[2])),"foreground",os.tcgetpgrp(f))',target.tty,String(target.pid)],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));}catch(e){console.error(e.stderr?.toString());}}assert.equal(stopped.ok,true,stopped.message);await foregroundDone;assert.equal(JSON.parse(await readFile(signalFile,'utf8')).signal,2);
  const home=path.join(temp,'home');await mkdir(path.join(home,'.claude'),{recursive:true});
  const config=path.join(home,'.claude/settings.json');await writeFile(config,JSON.stringify({permissions:{allow:['Read']},hooks:{PreToolUse:[{hooks:[{type:'command',command:'echo my-existing-hook'}]}]}}));
  const installer=path.join(bin,'install-hooks');const args=['--home',home,'--hook','/Applications/Agent Deck.app/Contents/MacOS/deck-hook','--agents','claude'];
  execFileSync(installer,args);execFileSync(installer,args);
  let settings=JSON.parse(await readFile(config,'utf8'));assert.deepEqual(settings.permissions,{allow:['Read']});assert.equal(settings.hooks.PreToolUse.length,2);assert.equal(settings.hooks.PermissionRequest[0].hooks[0].timeout,310);
  execFileSync(installer,[...args,'--uninstall']);settings=JSON.parse(await readFile(config,'utf8'));assert.equal(settings.hooks.PreToolUse.length,1);assert.equal(settings.hooks.PermissionRequest,undefined);
  const codexConfig=path.join(home,'.codex/config.toml');await mkdir(path.dirname(codexConfig),{recursive:true});
  const unrelated='notify = ["/usr/bin/say", "done"]\nmodel = "user-choice"\n';await writeFile(codexConfig,unrelated);
  const existingCodexHooks={hooks:{SessionStart:[{matcher:'*',hooks:[{type:'command',command:'node /old/agent-hook.mjs codex SessionStart'},{type:'command',command:'echo preserve-this-handler'}]}]}};
  await writeFile(path.join(home,'.codex/hooks.json'),JSON.stringify(existingCodexHooks));
  execFileSync(installer,['--home',home,'--hook','/Applications/Agent Deck.app/Contents/MacOS/deck-hook','--agents','codex']);assert.equal(await readFile(codexConfig,'utf8'),unrelated);
  const migrated=await readFile(path.join(home,'.codex/hooks.json'),'utf8');assert(migrated.includes('preserve-this-handler'));assert(!migrated.includes('agent-hook.mjs'));
  const codexHooks=path.join(home,'.codex/hooks.json');
  const ownedHooks=JSON.parse(await readFile(codexHooks,'utf8'));
  for(const event of ['SessionStart','UserPromptSubmit','Stop','Interrupt','SessionEnd']) {
    assert(ownedHooks.hooks[event].some(group=>group.hooks?.some(h=>h.command.includes('deck-hook" codex '+event))),'Missing native Codex lifecycle '+event);
  }
  const lifecycleBefore=await readFile(codexHooks,'utf8');
  execFileSync(installer,['--home',home,'--hook','/Applications/Agent Deck.app/Contents/MacOS/deck-hook','--agents','codex']);
  assert.equal(await readFile(codexHooks,'utf8'),lifecycleBefore,'Codex hook install is not idempotent');
  await mkdir(path.join(home,'.gemini'),{recursive:true});
  execFileSync(installer,['--home',home,'--hook','/Applications/Agent Deck.app/Contents/MacOS/deck-hook','--agents','gemini']);
  const geminiHooks=JSON.parse(await readFile(path.join(home,'.gemini/settings.json'),'utf8'));
  assert.equal(geminiHooks.hooks.BeforeTool[0].hooks[0].timeout,310000,'Gemini BeforeTool approval timeout must be milliseconds');
  assert.equal(geminiHooks.hooks.AfterTool[0].hooks[0].timeout,3000,'Gemini notification timeout must be milliseconds');
  const chain=['/Applications/Codex Computer Use.app/Sky','turn-ended','--previous-notify',JSON.stringify(['/old/agent-hook.mjs','codex','turn-ended'])];
  await writeFile(codexConfig,'notify = '+JSON.stringify(chain)+'\nmodel = "user-choice"\n');
  execFileSync(installer,['--home',home,'--hook','/Applications/Agent Deck.app/Contents/MacOS/deck-hook','--agents','codex']);
  const chained=await readFile(codexConfig,'utf8');const parsed=JSON.parse(chained.split('\n')[0].replace(/^notify = /,''));assert.equal(parsed[0],chain[0]);assert.equal(JSON.parse(parsed[3])[0],'/Applications/Agent Deck.app/Contents/MacOS/deck-hook');assert(chained.includes('model = "user-choice"'));
  const plugin=path.join(temp,'plugin');await mkdir(plugin,{recursive:true});await writeFile(path.join(plugin,'AiAgentDeckPlugin.dll'),'fixture');
  const profilePath=path.join(home,'.local/share/Loupedeck/Applications/TestDevice/@_defaultmac/Profiles/default/ProfileInfo.json');await mkdir(path.dirname(profilePath),{recursive:true});
  const custom={name:'user-page',controls:[{pressAction:'user-action'}]};
  await writeFile(profilePath,JSON.stringify({additionalNativePluginNames:['UserPlugin'],layout:{layoutModes:[{workspaces:[{pressPages:[custom]}]}]}}));
  const keypadArgs=['--home',home,'--agents','none','--keypad','--plugin-dir',plugin];
  execFileSync(installer,keypadArgs);execFileSync(installer,keypadArgs);
  let profile=JSON.parse(await readFile(profilePath,'utf8'));assert(profile.additionalNativePluginNames.includes('UserPlugin'));assert.equal(profile.layout.layoutModes[0].workspaces[0].pressPages.length,2);assert.equal(profile.layout.layoutModes[0].workspaces[0].pressPages[0].controls.length,9);
  execFileSync(installer,[...keypadArgs,'--uninstall']);profile=JSON.parse(await readFile(profilePath,'utf8'));assert.deepEqual(profile.layout.layoutModes[0].workspaces[0].pressPages,[custom]);
  await writeFile(config,'{ broken');assert.throws(()=>execFileSync(installer,args,{stdio:'pipe'}));assert.equal(await readFile(config,'utf8'),'{ broken');
  await gui('test-gui');
  const voiceHook=hook('voice-native-fixture');
  let voiceRequest;
  for(let i=0;i<100;i++){snapshot=await get();voiceRequest=snapshot.requests.find(r=>snapshot.sessions[r.sessionId].providerSessionId==='voice-native-fixture');if(voiceRequest)break;await delay(20);}
  assert(voiceRequest,'Voice fixture did not register');
  const prepareVoice=clientID=>fetch(base+'/supervisor/voice/prepare',{method:'POST',headers,body:JSON.stringify({clientID,requestID:voiceRequest.id})});
  assert.equal((await prepareVoice('other-gui')).status,409,'Wrong app lease minted voice proof');
  const proof=await(await prepareVoice('test-gui')).json();assert(proof.token);
  const voiceResult=await action({sessionId:voiceRequest.sessionId,requestId:voiceRequest.id,choiceId:'allow',revision:voiceRequest.revision,voiceConfirmation:proof.token});
  assert(voiceResult.ok,voiceResult.message);await voiceHook.done;
  assert.equal(JSON.parse(voiceHook.output()).hookSpecificOutput.decision.behavior,'allow');
  assert.equal((await action({sessionId:voiceRequest.sessionId,requestId:voiceRequest.id,choiceId:'allow',revision:voiceRequest.revision,voiceConfirmation:proof.token})).ok,false,'Voice proof was reused');
  console.log('PASS: GUI-owned exact-session focus, authenticated transport, private socket, separate sessions, exact approval, hold enforcement, one-time delivery, disconnected-hook cancellation, managed Codex request-specific approvals, verified foreground-process interruption, idempotent hook installation, safe uninstall, invalid-config preservation.');
} catch(error) { console.error(logs.slice(-4000)); throw error; } finally { for(const child of hooks)if(child.exitCode===null)child.kill();if(service.exitCode===null && service.signalCode===null){const exited=new Promise(r=>service.once('exit',r));service.kill('SIGTERM');await exited;} }
