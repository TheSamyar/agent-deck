#!/usr/bin/env node
// Disposable native owner process; never touches a real coding session.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import crypto from 'node:crypto';
import {mkdtemp,mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import {setTimeout as delay} from 'node:timers/promises';
const root=path.resolve(import.meta.dirname,'..'),bin=path.join(root,'native/.build/debug');
const temp=await mkdtemp(path.join(os.tmpdir(),'deck-lifecycle-')),runtime=path.join(temp,'run');
const probe=net.createServer();await new Promise(r=>probe.listen(0,'127.0.0.1',r));const port=probe.address().port;await new Promise(r=>probe.close(r));
const env={...process.env,AGENT_DECK_RUNTIME:runtime,AGENT_DECK_SUPPORT:path.join(temp,'data'),AGENT_DECK_PORT:String(port),AGENT_DECK_DISABLE_SCAN:'0',CODEX_HOME:path.join(temp,'codex-home'),__CFBundleIdentifier:'com.apple.Terminal',TTY:'/dev/ttys999',AGENT_DECK_HOST_INSTANCE:'lifecycle-fixture'};
await mkdir(env.CODEX_HOME);
const source=path.join(temp,'owner.c'),ownerPath=path.join(temp,'codex');
await writeFile(source,`#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
extern char **environ;
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 pid_t child;char *args[]={argv[1],"codex","UserPromptSubmit","{\\"session_id\\":\\"owner-lifecycle\\",\\"cwd\\":\\"/test/disposable-owner\\"}",NULL};
 if(posix_spawn(&child,argv[1],NULL,NULL,args,environ)!=0)return 3;
 int status;waitpid(child,&status,0);puts("ready");fflush(stdout);
 while(1)pause();
}
`);
execFileSync('/usr/bin/clang',[source,'-o',ownerPath],{stdio:'pipe'});
let service=spawn(path.join(bin,'deck-service'),[],{env,stdio:['ignore','pipe','pipe']});
let logs='';service.stderr.on('data',data=>logs+=data);
let owner,bridgedChild;
try {
 let connection;
 for(let i=0;i<100;i++){try{connection=JSON.parse(await readFile(path.join(runtime,'connection.json'),'utf8'));break;}catch{await delay(50);}}
 assert(connection,'Service did not start: '+logs);
 const headers={Authorization:'Bearer '+connection.token};
 const status=async()=>{const response=await fetch(`http://127.0.0.1:${port}/status`,{headers,signal:AbortSignal.timeout(4000)});assert(response.ok);return response.json();};
 owner=spawn(ownerPath,[path.join(bin,'deck-hook')],{env,stdio:['ignore','pipe','pipe']});
 let ready='';owner.stdout.on('data',data=>ready+=data);
 for(let i=0;i<100&&!ready.includes('ready');i++)await delay(50);
 assert(ready.includes('ready'),'Fixture owner did not report its hook');
 let session;
 for(let i=0;i<100;i++){session=Object.values((await status()).sessions).find(s=>s.providerSessionId==='owner-lifecycle');if(session)break;await delay(50);}
 assert(session,'Hook did not register owner');assert.equal(session.pid,owner.pid);assert(session.processBirth,'Owner birth must be bound');assert.equal(session.status,'WORKING');
 await delay(2300);
 assert.equal((await status()).sessions[session.id].status,'WORKING','Health scan incorrectly removed a live owner');
 const ended=new Promise(resolve=>owner.once('exit',resolve));owner.kill('SIGTERM');await ended;
 let after;
 for(let i=0;i<100;i++){after=(await status()).sessions[session.id];if(after.status==='DISCONNECTED')break;await delay(50);}
 assert.equal(after.status,'DISCONNECTED','Exited owner remained active');
 assert.equal(after.capabilities.approve,false);assert.equal(after.capabilities.interrupt,false);
 // Resume the provider thread under a new owner; the stable session must bind its new owner.
 owner=spawn(ownerPath,[path.join(bin,'deck-hook')],{env,stdio:['ignore','pipe','pipe']});
 let resumed;
 for(let i=0;i<100;i++){resumed=Object.values((await status()).sessions).find(s=>s.providerSessionId==='owner-lifecycle'&&s.pid===owner.pid);if(resumed)break;await delay(50);}
 assert(resumed,'Resumed Codex thread did not register its new owner');
 assert.equal(resumed.id,session.id);
 assert.notEqual(resumed.processBirth,session.processBirth);
 assert.equal(resumed.status,'WORKING');
 // Reconnect after a client-side stream interruption using real snapshots.
 const streamSnapshot=async(credentials)=>{
  const controller=new AbortController();
  const timeout=setTimeout(()=>controller.abort(),4000);
  try {
   const response=await fetch(`http://127.0.0.1:${port}/events`,{headers:credentials,signal:controller.signal});
   assert(response.ok,'Event stream rejected current credentials');
   const reader=response.body.getReader();const decoder=new TextDecoder();let buffer='';
   try {
    for(;;){
     const {value,done}=await reader.read();assert(!done,'Event stream ended before a snapshot');
     buffer+=decoder.decode(value,{stream:true});
     let newline;
     while((newline=buffer.indexOf('\n'))!==-1){
      const line=buffer.slice(0,newline).replace(/\r$/,'');buffer=buffer.slice(newline+1);
      if(line.startsWith('data: '))return JSON.parse(line.slice(6));
     }
    }
   }
   finally {await reader.cancel();}
  } finally {clearTimeout(timeout);controller.abort();}
 };
 const beforeRestart=await streamSnapshot(headers);
 const reconnected=await streamSnapshot(headers);
 assert.equal(reconnected.instanceId,beforeRestart.instanceId);
 assert.equal(reconnected.sessions[session.id].status,'WORKING');
 // Delete only the disposable runtime. A live orphaned listener must exit.
 const exited=new Promise(resolve=>service.once('exit',resolve));
 await rm(runtime,{recursive:true,force:true});
 await Promise.race([exited,delay(8000).then(()=>{throw new Error('Service retained orphaned runtime endpoints');})]);
 service=spawn(path.join(bin,'deck-service'),[],{env,stdio:['ignore','pipe','pipe']});
 service.stderr.on('data',data=>logs+=data);
 let replacement;
 for(let i=0;i<100;i++){try{replacement=JSON.parse(await readFile(path.join(runtime,'connection.json'),'utf8'));break;}catch{await delay(50);}}
 assert(replacement,'Replacement service did not publish connection files: '+logs);
 assert.notEqual(replacement.token,connection.token,'Restart reused credentials');
 const rejected=await fetch(`http://127.0.0.1:${port}/status`,{headers,signal:AbortSignal.timeout(4000)});
 assert([401,403].includes(rejected.status),'Restart accepted obsolete credentials');
 const recovered=await fetch(`http://127.0.0.1:${port}/status`,{headers:{Authorization:'Bearer '+replacement.token},signal:AbortSignal.timeout(4000)});
 assert(recovered.ok,'Replacement service unavailable');
 const restartedStream=await streamSnapshot({Authorization:'Bearer '+replacement.token});
 assert.notEqual(restartedStream.instanceId,beforeRestart.instanceId,'Restart reused stream identity');
 assert(['DISCONNECTED','UNKNOWN'].includes((await recovered.json()).sessions[session.id].status),'Restored history claimed live activity');
 // Verify Cursor-bridged terminal interrupt (stop) through the private /bridge socket.
 const replacementHeaders={Authorization:'Bearer '+replacement.token};
 const replacementStatus=async()=>{const r=await fetch(`http://127.0.0.1:${port}/status`,{headers:replacementHeaders,signal:AbortSignal.timeout(4000)});assert(r.ok);return r.json();};
 const postAction=async(body)=>{const r=await fetch(`http://127.0.0.1:${port}/action`,{method:'POST',headers:{...replacementHeaders,'Content-Type':'application/json'},body:JSON.stringify({requestId:'',choiceId:'',heldMs:0,...body}),signal:AbortSignal.timeout(5000)});assert(r.ok);return r.json();};
 const unixPost=(route,body)=>new Promise((resolve,reject)=>{
  const data=JSON.stringify(body);
  const req=http.request({socketPath:path.join(runtime,'deck.sock'),path:route,method:'POST',headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(data)},timeout:4000},res=>{
   let raw='';res.on('data',chunk=>raw+=chunk);res.on('end',()=>{try{resolve(JSON.parse(raw));}catch(error){reject(error);}});
  });
  req.on('error',reject);req.on('timeout',()=>req.destroy(new Error(`Unix POST ${route} timed out`)));req.end(data);
 });
 bridgedChild=spawn('/bin/sleep',['30'],{stdio:'ignore'});
 const bridgeCwd=path.join(temp,'cursor-bridge-project');
 assert.equal((await unixPost('/hook/cursor/beforeSubmitPrompt',{
  data:{conversation_id:'bridge-stop-fixture',cwd:bridgeCwd},
  env:{ppid:bridgedChild.pid,bundleId:'com.todesktop.230313mzl4w4u92',hostInstanceId:'cursor-bridge-fixture',tty:''}
 })).ok,true);
 assert.equal((await unixPost('/hook/cursor/beforeSubmitPrompt',{
  data:{conversation_id:'bridge-other-fixture',cwd:path.join(temp,'cursor-other-project')},
  env:{ppid:process.pid,bundleId:'com.todesktop.230313mzl4w4u92',hostInstanceId:'cursor-other-fixture',tty:''}
 })).ok,true);
 const bridgePayload={
  instanceId:'cursor-bridge-fixture',
  hostPid:process.pid,
  workspaceFolders:[bridgeCwd],
  terminals:[{id:'term-1',shellPid:bridgedChild.pid,processTree:[bridgedChild.pid]}]
 };
 assert.equal((await unixPost('/bridge',bridgePayload)).ok,true);
 let bridgeSession,otherSession;
 for(let i=0;i<40;i++){
  if(i>0&&i%10===0)await unixPost('/bridge',bridgePayload);
  const current=await replacementStatus();
  const list=Object.values(current.sessions);
  bridgeSession=list.find(s=>s.providerSessionId==='bridge-stop-fixture');
  otherSession=list.find(s=>s.providerSessionId==='bridge-other-fixture');
  if(bridgeSession?.capabilities?.focus===true&&bridgeSession?.capabilities?.interrupt===true&&otherSession)break;
  await delay(100);
 }
 assert(bridgeSession,'Cursor bridge session did not register');
 assert(otherSession,'Secondary active Cursor session did not register');
 assert.equal(bridgeSession.capabilities.focus,true,'Cursor bridge focus capability was not enabled');
 assert.equal(bridgeSession.capabilities.interrupt,true,'Cursor bridge interrupt capability was not enabled');
 assert.equal((await postAction({id:crypto.randomUUID(),action:'select',sessionId:otherSession.id})).ok,true);
 assert.equal((await replacementStatus()).selectedSessionId,otherSession.id,'Select did not retain secondary session');
 const unheldStop=await postAction({id:crypto.randomUUID(),action:'stop',sessionId:bridgeSession.id,heldMs:0});
 assert.equal(unheldStop.ok,false,'Unheld stop action must be rejected');
 const stopCommandId=crypto.randomUUID();
 const stopRequest=postAction({id:stopCommandId,action:'stop',sessionId:bridgeSession.id,heldMs:700});
 let command;
 for(let i=0;i<30;i++){
  const poll=await unixPost('/bridge',bridgePayload);
  if(poll.command?.id===stopCommandId){command=poll.command;break;}
  await delay(50);
 }
 assert(command,'Service did not queue Cursor bridge stop command');
 assert.equal(command.action,'stop');
 assert.equal(command.terminalId,'term-1');
 const ackPoll=await unixPost('/bridge',{...bridgePayload,result:{id:stopCommandId,ok:true,message:'Interrupt sent to the identified terminal'}});
 assert.equal(ackPoll.ok,true);
 const stopResult=await stopRequest;
 assert.equal(stopResult.ok,true);
 assert.equal(stopResult.state,'acknowledged');
 assert.equal(stopResult.commandId,stopCommandId);
 assert.equal(stopResult.message,'Interrupt sent to the identified terminal');
 assert.equal((await replacementStatus()).selectedSessionId,otherSession.id,'Bridge stop unexpectedly changed selectedSessionId');
 // Verify focusInApp failure preserves commandId and bridged focus succeeds with GUI + bridge acks.
 const focusFailId=crypto.randomUUID();
 const focusFail=await postAction({id:focusFailId,action:'focus',sessionId:bridgeSession.id});
 assert.equal(focusFail.ok,false,'Focus without connected GUI must fail');
 assert.equal(focusFail.commandId,focusFailId,'Failed bridged focus must preserve commandId');
 const guiPoll=async(replies=[])=>{const r=await fetch(`http://127.0.0.1:${port}/gui/control`,{method:'POST',headers:{...replacementHeaders,'Content-Type':'application/json'},body:JSON.stringify({clientID:'lifecycle-gui',accessibilityGranted:true,replies}),signal:AbortSignal.timeout(4000)});assert(r.ok);return r.json();};
 await guiPoll([]);
 const focusCmdId=crypto.randomUUID();
 const focusRequest=postAction({id:focusCmdId,action:'focus',sessionId:bridgeSession.id});
 let focusGuiReq;
 for(let i=0;i<30;i++){
  const delivery=await guiPoll([]);
  focusGuiReq=(delivery.requests||[]).find(req=>req.kind==='focus');
  if(focusGuiReq)break;
  await delay(50);
 }
 assert(focusGuiReq,'Service did not enqueue GUI focus request');
 await guiPoll([{id:focusGuiReq.id,result:{ok:true,state:'acknowledged',message:'GUI raised',commandId:''}}]);
 let focusCmd;
 for(let i=0;i<30;i++){
  const poll=await unixPost('/bridge',bridgePayload);
  if(poll.command?.id===focusCmdId){focusCmd=poll.command;break;}
  await delay(50);
 }
 assert(focusCmd,'Service did not queue Cursor bridge focus command');
 assert.equal(focusCmd.action,'focus');
 assert.equal(focusCmd.terminalId,'term-1');
 assert.equal((await unixPost('/bridge',{...bridgePayload,result:{id:focusCmdId,ok:true,message:'Revealed the identified terminal'}})).ok,true);
 const focusOk=await focusRequest;
 assert.equal(focusOk.ok,true);
 assert.equal(focusOk.state,'acknowledged');
 assert.equal(focusOk.commandId,focusCmdId);
 assert.equal(focusOk.message,'Revealed the identified terminal');
 assert.equal((await replacementStatus()).selectedSessionId,bridgeSession.id,'Successful bridged focus did not select session');
 console.log('PASS: Codex owner lifecycle, resume, stream reconnection, runtime recovery, rotated credentials, inactive restored history, and Cursor-bridged terminal interrupt.');
} finally {
 bridgedChild?.kill('SIGTERM');owner?.kill('SIGTERM');service.kill('SIGTERM');
 await rm(temp,{recursive:true,force:true});
}
