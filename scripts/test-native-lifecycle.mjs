#!/usr/bin/env node
// Disposable native owner process; never touches a real coding session.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,rm} from 'node:fs/promises';
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
let owner;
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
 console.log('PASS: Codex owner lifecycle, resume, stream reconnection, runtime recovery, rotated credentials, and inactive restored history.');
} finally {owner?.kill('SIGTERM');service.kill('SIGTERM');}
