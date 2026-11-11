#!/usr/bin/env node
// Read-only gate inventory. Does not build, install, sign, notarize, or publish.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';

const root=path.resolve(import.meta.dirname,'..');
const appIndex=process.argv.indexOf('--app');
if(appIndex>=0&&(!process.argv[appIndex+1]||process.argv[appIndex+1].startsWith('--'))){
  console.error('--app requires a bundle path.');
  process.exit(2);
}
const candidate=appIndex>=0?path.resolve(process.argv[appIndex+1]):path.join(root,'dist/Agent Deck.app');
function git(args){
  const result=spawnSync('git',args,{cwd:root,encoding:'utf8'});
  if(result.status!==0)throw Error(`Cannot identify checkout: ${result.stderr||result.error?.message}`);
  return result.stdout.trim();
}
function inspectBundle(bundle){
  const executable=path.join(bundle,'Contents/MacOS/AgentDeck');
  return {path:bundle,exists:fs.existsSync(bundle),executableSha256:fs.existsSync(executable)?crypto.createHash('sha256').update(fs.readFileSync(executable)).digest('hex'):null};
}
function check(name,script,args=[]){
  const result=spawnSync(process.execPath,[path.join(root,'scripts',script),...args],{
    cwd:root,encoding:'utf8',timeout:60000,maxBuffer:1024*1024,
  });
  return {
    name,command:[process.execPath,`scripts/${script}`,...args],
    status:result.status===0?'passed':result.error?.code==='ETIMEDOUT'?'timed_out':'failed',
    exitCode:result.status,
    detail:String(result.stderr||result.stdout||result.error?.message||'No diagnostic output').trim().slice(-4000),
  };
}
const checkout={commit:git(['rev-parse','HEAD']),dirty:git(['status','--porcelain']).length>0};
const automated=[
  check('Public candidate package','verify-native-release.mjs',['--public','--app',candidate]),
  check('Installed app and connected MasterHUB','verify-native-live.mjs'),
];
console.log(JSON.stringify({
  checkedAt:new Date().toISOString(),checkout,
  artifacts:{candidate:inspectBundle(candidate),installed:inspectBundle(path.join(os.homedir(),'Applications/Agent Deck.app'))},
  provenance:'Checkout identifies the source reviewed; it does not prove either app was built from this commit.',
  automated,automatedChecksPassed:automated.every(item=>item.status==='passed'),
  manualGates:[
    {name:'Physical controls and reconnect',status:'unverified',evidence:'Record label/action pairs, press/hold behavior, stale-layout rejection, unplug/replug, and sleep/wake on the exact candidate. Use disposable requests.'},
    {name:'Additional Macs and accessibility',status:'unverified',evidence:'Record Intel and Apple Silicon execution, VoiceOver, contrast, Reduce Motion, sustained performance, and tested macOS versions.'},
    {name:'Signed update delivery',status:'unverified',evidence:'Review the versioned ZIP, checksum, signed feed, and intended HTTPS artifact/feed reachability. Do not publish to perform this check.'},
    {name:'Publication approval',status:'unverified',evidence:'Obtain explicit approval for the reviewed candidate and launch assets before publishing.'},
  ],
  publicationReadiness:'Not established by automated checks; complete the evidence record in docs/RELEASE-ACCEPTANCE.md.',
},null,2));
if(automated.some(item=>item.status!=='passed'))process.exitCode=1;
