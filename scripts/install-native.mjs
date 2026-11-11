#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {execFileSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
const root=path.resolve(import.meta.dirname,'..'), home=os.homedir();
const app=path.join(home,'Applications/Agent Deck.app');
if(!fs.existsSync(app))throw Error('Build and install the app first: node scripts/build-native.mjs --universal --release --install');
const withKeypad=process.argv.includes('--with-keypad');
const keypadService='/Applications/Utilities/LogiPluginService.app';
if(withKeypad&&(!fs.existsSync(path.join(app,'Contents/Resources/KeypadPlugin/AiAgentDeckPlugin.dll'))||!fs.existsSync(keypadService)))throw Error('Optional vendor-keypad setup requires the bundled plugin and installed Logitech service. MasterHUB installation does not require --with-keypad.');
execFileSync('codesign',['--verify','--deep','--strict',app],{stdio:'inherit'});
const connectionFile=path.join(home,'Library/Caches/AgentDeck/connection.json');
if(fs.existsSync(connectionFile)){
  let active;
  try{const endpoint=JSON.parse(fs.readFileSync(connectionFile,'utf8'));const response=await fetch(`http://127.0.0.1:${endpoint.port}/status`,{headers:{Authorization:`Bearer ${endpoint.token}`},signal:AbortSignal.timeout(1500)});if(response.ok)active=await response.json();}catch{}
  if(active?.requests?.length)throw Error('Finish the pending requests in Agent Deck before restarting its service. The current service and requests were preserved.');
}
let legacy=false;
try{const response=await fetch('http://127.0.0.1:19420/status',{signal:AbortSignal.timeout(1500)});const value=await response.json();legacy=value.ok&&value.protocolVersion===undefined;}catch{}
const port=legacy?19421:19420;
const keepLegacy=process.argv.includes('--keep-legacy');
const label='com.aiagentdeck.service', domain=`gui/${process.getuid()}`;
const plist=path.join(home,'Library/LaunchAgents',label+'.plist');
const log=path.join(home,'Library/Logs/AgentDeck-service.log');
const xml=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const runtime=path.join(home,'Library/Caches/AgentDeck');
fs.mkdirSync(path.dirname(plist),{recursive:true});fs.mkdirSync(runtime,{recursive:true,mode:0o700});
const service=path.join(app,'Contents/Helpers/DeckService.bundle/Contents/MacOS/deck-service');
const text=`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array><string>${xml(service)}</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>5</integer><key>StandardOutPath</key><string>${xml(log)}</string><key>StandardErrorPath</key><string>${xml(log)}</string><key>EnvironmentVariables</key><dict><key>AGENT_DECK_PORT</key><string>${port}</string><key>AGENT_DECK_APP</key><string>${xml(app)}</string><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict></dict></plist>`;
if(fs.existsSync(plist)&&!fs.existsSync(plist+'.pre-native.bak'))fs.copyFileSync(plist,plist+'.pre-native.bak');
try{execFileSync('launchctl',['bootout',domain,plist],{stdio:'ignore'});}catch{}
fs.writeFileSync(plist,text);
execFileSync('launchctl',['bootstrap',domain,plist]);
let ready=false;
for(let i=0;i<100;i++){
  try{const endpoint=JSON.parse(fs.readFileSync(path.join(runtime,'connection.json'),'utf8'));const response=await fetch(`http://127.0.0.1:${endpoint.port}/status`,{headers:{Authorization:`Bearer ${endpoint.token}`},signal:AbortSignal.timeout(1000)});if(response.ok){ready=true;break;}}catch{}
  await delay(100);
}
if(!ready)throw Error('Native service did not become ready. Existing legacy service was preserved. Check '+log);
execFileSync(path.join(app,'Contents/Resources/install-hooks'),['--agents','claude,cursor,gemini,codex','--editor',...(withKeypad?['--keypad']:[])],{stdio:'inherit'});
// Once native hooks are installed, retire only Agent Deck's old Node LaunchAgent.
if(!keepLegacy){
  const oldLabel='com.ai-agent-deck.daemon';
  const oldPlist=path.join(home,'Library/LaunchAgents',oldLabel+'.plist');
  try{execFileSync('launchctl',['bootout',domain,oldPlist],{stdio:'ignore'});}catch{}
  execFileSync('launchctl',['disable',`${domain}/${oldLabel}`]);
}
// Vendor-keypad support is explicit; a MasterHUB Mac needs no Logitech software.
if(withKeypad){
  try{execFileSync('killall',['LogiPluginService'],{stdio:'ignore'});}catch{}
  execFileSync('open',['-g',keypadService]);
}
execFileSync('open',[app]);
console.log(`Native service ready on port ${port}. ${keepLegacy?'Legacy service retained by explicit request.':'Native runtime only; Node daemon disabled.'}`);
console.log('Cursor extension installed; reload editor windows when convenient to enable exact terminal targeting.');
