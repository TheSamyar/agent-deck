#!/usr/bin/env node
// All agent processes are disposable fixtures. No API credentials or real tasks are used.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,writeFile,readFile,mkdir,realpath} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import {setTimeout as delay} from 'node:timers/promises';
const root=path.resolve(import.meta.dirname,'..');
const temp=await realpath(await mkdtemp(path.join(os.tmpdir(),'deck-supervisor-')));
const runtime=path.join(temp,'run'),support=path.join(temp,'data');
const probe=net.createServer();await new Promise(r=>probe.listen(0,'127.0.0.1',r));
const port=probe.address().port;await new Promise(r=>probe.close(r));
const binaries={};
for(const provider of ['codex','claude','cursor']){
 const binary=path.join(temp,provider);binaries[provider]=binary;
 await writeFile(binary,`#!/usr/bin/env node
const fs=require('node:fs');const args=process.argv.slice(2);const provider=${JSON.stringify(provider)};
// Subscription-only launches probe sign-in before task execution. These are fake accounts.
if(provider==='codex'&&args.includes('login')&&args.includes('status')){console.log('Logged in using ChatGPT');process.exit(0);}
if(provider==='claude'&&args.includes('auth')&&args.includes('status')){console.log(JSON.stringify({loggedIn:true,authMethod:'claude.ai',apiProvider:'firstParty',subscriptionType:'pro'}));process.exit(0);}
if(provider==='cursor'&&args.includes('status')){console.log(JSON.stringify({isAuthenticated:true,hasAccessToken:true,hasRefreshToken:true}));process.exit(0);}
const emit=x=>process.stdout.write(JSON.stringify(x)+'\\n');
let prompt='';
const run=()=>{
 const resume=args.includes('--resume')?args[args.indexOf('--resume')+1]:args.includes('resume')?args[args.indexOf('resume')+2]:null;
 fs.appendFileSync(${JSON.stringify(path.join(temp,'calls.jsonl'))},JSON.stringify({provider,args,prompt,cwd:process.cwd(),resume})+'\\n');
 const id=resume||provider+'-exact-session';
 if(provider==='codex')emit({type:'thread.started',thread_id:id});else emit({type:'system',subtype:'init',session_id:id});
 if(prompt.includes('WAIT_FOREVER')){setInterval(()=>{},1000);return;}
 setTimeout(()=>{
 if(prompt.includes('IO_STRESS'))process.stderr.write('fixture stderr '.repeat(20000));
 if(provider==='codex'){
 emit({type:'item.completed',item:{type:'agent_message',text:'Implemented. Fixture tests passed.'}});emit({type:'turn.completed'});
 }else emit({type:'result',subtype:'success',session_id:id,result:'Implemented. Fixture tests passed.',is_error:false,permission_denials:prompt.includes('DENIED')?[{}]:[]});
 },150);
};
if(provider==='cursor'){prompt=args.at(-1);run();}else{process.stdin.on('data',x=>prompt+=x);process.stdin.on('end',run);}
`,{mode:0o700});
}
const env={...process.env,AGENT_DECK_RUNTIME:runtime,AGENT_DECK_SUPPORT:support,AGENT_DECK_PORT:String(port),AGENT_DECK_DISABLE_SCAN:'1'};
for(const [provider,binary] of Object.entries(binaries))env['AGENT_DECK_SUPERVISOR_'+provider.toUpperCase()+'_BINARY']=binary;
// Do not discover a real Gemini install on the developer's machine during fixtures.
env.AGENT_DECK_SUPERVISOR_GEMINI_BINARY=path.join(temp,'unavailable-gemini');
let service,token,logs='';
async function boot(){
 service=spawn(path.join(root,'native/.build/debug/deck-service'),[],{env,stdio:['ignore','pipe','pipe']});
 service.stderr.on('data',x=>logs+=x);service.stdout.on('data',x=>logs+=x);
 for(let i=0;i<100;i++){try{const endpoint=JSON.parse(await readFile(path.join(runtime,'connection.json'),'utf8'));token=endpoint.token;
 const response=await fetch('http://127.0.0.1:'+port+'/supervisor/tasks',{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(1000)});
 if(response.ok)return;}catch{}await delay(50);}
 throw Error('Service did not start: '+logs);
}
async function stop(){const exited=new Promise(r=>service.once('exit',r));service.kill('SIGTERM');await exited;}
async function request(route,body){const response=await fetch('http://127.0.0.1:'+port+'/supervisor/'+route,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(5000)});assert(response.ok);return response.json();}
async function waitFor(id,state){for(let i=0;i<100;i++){const task=(await request('tasks')).find(t=>t.id===id);if(task?.state===state)return task;await delay(30);}throw Error('Task did not reach '+state+': '+JSON.stringify((await request('tasks')).find(t=>t.id===id))+'\n'+logs);}
try{
 await boot();
 const unauth=await fetch('http://127.0.0.1:'+port+'/supervisor/tasks');assert.equal(unauth.status,401);
 const origin=await fetch('http://127.0.0.1:'+port+'/supervisor/tasks',{headers:{Authorization:'Bearer '+token,Origin:'https://example.com'}});assert.equal(origin.status,403);
 assert.deepEqual(await request('availability'),{codex:true,claude:true,cursor:true,gemini:false});
 for(const provider of ['codex','claude','cursor']){
  const cwd=path.join(temp,provider+'-project');await mkdir(cwd);
  assert.equal((await request('start',{provider,cwd,goal:'Fix the fixture',criteria:'Fixture tests pass'})).ok,true);
  let task=(await request('tasks')).find(t=>t.provider===provider);
  assert.equal((await request('start',{provider,cwd,goal:'Duplicate',criteria:'None'})).ok,false,'Parallel project writer must be rejected');
  task=await waitFor(task.id,'review');assert.equal(task.session,provider+'-exact-session');assert.equal(task.turns,1);
  assert.equal(task.pid,undefined,'Short-lived child termination must be observed after stdout EOF');
  assert.equal(task.result.trim(),'Implemented. Fixture tests passed.');
  assert.equal(await realpath(task.cwd),await realpath(cwd));
  const body={id:task.id,revision:task.revision,prompt:'Verify the fixture tests.',automatic:false,command:provider+'-command'};
  assert.equal((await request('continue',{...body,revision:task.revision-1})).ok,false,'Stale review must be rejected');
  assert.equal((await request('continue',body)).ok,true);
  assert.equal((await request('continue',body)).ok,true,'Duplicate command should return its prior receipt');
  task=await waitFor(task.id,'review');assert.equal(task.turns,2,'Duplicate command must not launch another agent');
  assert.equal(task.pid,undefined,'Resumed child termination must release its process identity');
  const calls=(await readFile(path.join(temp,'calls.jsonl'),'utf8')).trim().split('\n').map(JSON.parse).filter(c=>c.provider===provider);
  assert.equal(calls.length,2);assert.equal(calls[1].resume,task.session,'Follow-up must use exact session');
  assert.equal(calls[1].cwd,cwd);
  assert.equal((await request('state',{id:task.id,revision:task.revision,done:true})).ok,true);
 }
 // Concurrent stderr backpressure must not starve session/HTTP/completion tasks.
 const stressGoals=Array.from({length:6},(_,index)=>'DENIED_IO_STRESS_'+index);
 await Promise.all(stressGoals.map(async goal=>{
  const cwd=path.join(temp,goal);await mkdir(cwd);
  assert.equal((await request('start',{provider:'claude',cwd,goal,criteria:'Deny and drain both pipes'})).ok,true);
 }));
 const stressTasks=(await request('tasks')).filter(task=>stressGoals.includes(task.goal));
 assert.equal(stressTasks.length,stressGoals.length);
 assert.equal((await request('availability')).claude,true,'HTTP handlers must stay responsive while process pipes drain');
 await Promise.all(stressTasks.map(async task=>{
  const denied=await waitFor(task.id,'blocked');
  assert.equal(denied.session,'claude-exact-session');
  assert.equal(denied.pid,undefined,'Finished stress task must release its process identity');
 }));
 const cwd=path.join(temp,'denied');await mkdir(cwd);
 assert.equal((await request('start',{provider:'claude',cwd,goal:'DENIED',criteria:'Permission handled'})).ok,true);
 let denied=(await request('tasks')).find(t=>t.goal==='DENIED');denied=await waitFor(denied.id,'blocked');
 assert.equal((await request('continue',{id:denied.id,revision:denied.revision,prompt:'Retry',automatic:true,command:'deny-retry'})).ok,false);
 const slow=path.join(temp,'slow');await mkdir(slow);
 await request('start',{provider:'codex',cwd:slow,goal:'WAIT_FOREVER',criteria:'Wait'});
 let pending=(await request('tasks')).find(t=>t.goal==='WAIT_FOREVER');
 for(let i=0;i<100&&!pending.session;i++){await delay(20);pending=(await request('tasks')).find(t=>t.id===pending.id);}
 assert(pending.session,'Session identity should be persisted before turn completion');
 await stop();await boot();
 pending=(await request('tasks')).find(t=>t.id===pending.id);assert.equal(pending.state,'blocked','Restart must not resume work automatically');
 assert.equal(pending.session,'codex-exact-session');
 assert.equal((await request('continue',{id:pending.id,revision:pending.revision,prompt:'Do not duplicate',automatic:false,command:'orphan-retry'})).ok,false,'A live orphan must block a duplicate writer');
 assert.equal((await request('state',{id:pending.id,revision:pending.revision,done:false})).ok,true);
 console.log('PASS: supervisor authentication, all three adapters, exact resume, stale/duplicate rejection, permission denial, and restart recovery.');
}finally{if(service?.exitCode===null)await stop();}
