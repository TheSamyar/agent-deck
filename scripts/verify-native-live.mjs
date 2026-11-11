#!/usr/bin/env node
// Read-only smoke check. Never sends presses, approvals, hooks, or preferences.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const home=os.homedir();
const runtime=path.join(home,'Library/Caches/AgentDeck');
const app=path.join(home,'Applications/Agent Deck.app');
try{execFileSync('codesign',['--verify','--deep','--strict',app],{stdio:['ignore','pipe','pipe']});}
catch(error){
  console.error(`FAIL: installed app signature verification did not pass: ${app}\n${String(error.stderr||error.message).trim()}\nRecovery: restricted automation can block macOS trust services. Repeat this read-only check with trust-service access before concluding the bundle was modified. If it still fails, build and verify a fresh candidate before replacing the installed app. Runtime and hardware checks have not run.`);
  process.exit(1);
}
const connection=JSON.parse(fs.readFileSync(path.join(runtime,'connection.json'),'utf8'));
assert(Number.isInteger(connection.port)&&connection.port>0&&connection.port<=65535,'Invalid local service port');
assert(typeof connection.token==='string'&&connection.token.length>0,'Missing local service authentication');
assert.equal(connection.serviceBundleIdentifier,'com.aiagentdeck.service','Service must have its own background bundle identity');
assert(Number.isInteger(connection.servicePid)&&connection.servicePid>0,'Missing service process identity');
const serviceExecutable=execFileSync('ps',['-p',String(connection.servicePid),'-o','comm='],{encoding:'utf8'}).trim();
assert.equal(serviceExecutable,path.join(app,'Contents/Helpers/DeckService.bundle/Contents/MacOS/deck-service'),'Service is running from an obsolete app path');
const registrations=execFileSync('lsappinfo',['list'],{encoding:'utf8'}).split(/\n(?=\d+\) )/);
const registration=registrations.find(block=>new RegExp(`\\bpid = ${connection.servicePid}\\b`).test(block));
assert(registration?.includes('type="BackgroundOnly"'),'Service must not register as a foreground app');

const response=await fetch(`http://127.0.0.1:${connection.port}/status`,{
 headers:{Authorization:`Bearer ${connection.token}`},signal:AbortSignal.timeout(4000)});
assert(response.ok,`Local service returned ${response.status}`);
const snapshot=await response.json();
const healthResponse=await fetch(`http://127.0.0.1:${connection.port}/health`,{
 headers:{Authorization:`Bearer ${connection.token}`},signal:AbortSignal.timeout(4000)});
assert(healthResponse.ok,'Service health check unavailable');
const serviceHealth=await healthResponse.json();
assert.equal(typeof serviceHealth.accessibilityGranted,'boolean','Invalid permission health response');
assert.equal(serviceHealth.controlHost,'app','Mac controls must run in the GUI app');
assert.equal(serviceHealth.guiConnected,true,'GUI control lease unavailable');
const hardware=JSON.parse(fs.readFileSync(path.join(runtime,'masterhub-diagnostics.json'),'utf8'));
assert.equal(hardware.surfaceTileCount,15,'MasterHUB must render all fifteen keys');
assert.equal(hardware.displayedKeys,15,'All fifteen key images must be written');
assert(Number.isFinite(hardware.updatedAt)&&Math.abs(Date.now()/1000-hardware.updatedAt)<30,'Hardware diagnostics must be fresh');
assert([hardware.keypadConnected,hardware.rollerConnected,hardware.knobsConnected,hardware.screenDialConnected].every(value=>value===true),'All four MasterHUB modules must be connected');
assert.equal(hardware.displayFailures,0,'Keypad display writes failed');
assert.equal(hardware.screenDialDisplayFailures,0,'Screen dial display writes failed');
assert.equal(hardware.rollerInitialization,0,'Roller HID startup request failed');
assert.equal(hardware.knobInitialization,0,'Small-dial HID startup request failed');

const unauthenticated=await fetch(`http://127.0.0.1:${connection.port}/status`,{signal:AbortSignal.timeout(4000)});
assert([401,403].includes(unauthenticated.status),'Runtime must reject unauthenticated access');
assert.equal(snapshot.protocolVersion,2,'Unexpected runtime protocol');
assert.equal(snapshot.tiles?.length,9,'Runtime must expose nine keypad positions');
assert(snapshot.pageCount>=1&&snapshot.page>=0&&snapshot.page<snapshot.pageCount,'Invalid page state');
const sessions=Object.values(snapshot.sessions??{});
// A resumed provider thread can have several process-bound historical records.
// Compare the newest event, rather than the first dictionary match.
const currentThread=process.env.CODEX_THREAD_ID ? sessions.filter(s=>s.agentId==='codex'&&s.providerSessionId===process.env.CODEX_THREAD_ID).sort((a,b)=>b.lastHookAt-a.lastHookAt)[0] : undefined;
const active=sessions.filter(s=>s.status!=='DISCONNECTED'&&s.status!=='UNKNOWN');
const health=JSON.parse(fs.readFileSync(path.join(runtime,'window-health.json'),'utf8'));
assert(Number.isInteger(health.pid)&&health.pid>0,'Missing GUI process identity');
const executable=execFileSync('ps',['-p',String(health.pid),'-o','comm='],{encoding:'utf8'}).trim();
assert.equal(executable,path.join(app,'Contents/MacOS/AgentDeck'),'Window health belongs to a stale or unrelated process');
assert.equal(health.visible,true,'Dashboard last reported hidden');
assert.equal(health.minimized,false,'Dashboard last reported minimized');
assert.equal(health.onScreen,true,'Dashboard last reported off-screen');
console.log(JSON.stringify({result:'PASS',installedSignature:'valid',localService:'authenticated; unauthenticated access rejected',serviceIdentity:'distinct background helper',serviceAccessibilityGranted:serviceHealth.accessibilityGranted,protocol:2,
 sessions:{observed:active.length,unobservedHistory:sessions.length-active.length},
 currentCodexThread:currentThread?{status:currentThread.status,eventAgeSeconds:Math.round((Date.now()-currentThread.lastHookAt)/1000)}:undefined,
 pendingRequests:snapshot.requests?.length??0,legacyKeypadPositions:9,masterhub:{keypadPositions:hardware.surfaceTileCount,displayedKeys:hardware.displayedKeys,displayFailures:hardware.displayFailures,modulesConnected:[hardware.keypadConnected,hardware.rollerConnected,hardware.knobsConnected,hardware.screenDialConnected].filter(Boolean).length},pages:snapshot.pageCount,
 dashboard:{process:'running',lastReportedVisible:health.visible,lastReportedOnScreen:health.onScreen},
 physicalControls:'not exercised; requires hands-on verification'},null,2));
