#!/usr/bin/env node
// Owned synthetic demos plus read-only live-app diagnostics. Never sends hardware
// inputs, decisions, prompts, preferences, or commands to real agents.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';

export function parseCPUTime(value) {
  const match=/^(?:(\d+)-)?(\d+):(\d+(?:\.\d+)?)(?::(\d+(?:\.\d+)?))?$/.exec(value);
  if(!match)throw Error(`Invalid process CPU time: ${value}`);
  const seconds=match[4]===undefined?Number(match[2])*60+Number(match[3]):Number(match[2])*3600+Number(match[3])*60+Number(match[4]);
  return Number(match[1]||0)*86400+seconds;
}
export function validateObservation(initial,current,maxAgeSeconds=90) {
  for(const name of Object.keys(initial.processes)) {
    const before=initial.processes[name],now=current.processes[name];
    if(!now||now.identity!==before.identity)throw Error(`${name} exited or its PID was reused`);
    if(!Number.isFinite(now.cpuSeconds)||!Number.isFinite(now.rssKB)||now.rssKB<0)throw Error(`${name} process metrics are invalid`);
    if(now.cpuSeconds<before.cpuSeconds)throw Error(`${name} CPU counter reset`);
  }
  const age=current.observedAt-current.hardware.updatedAt;
  if(!Number.isFinite(age)||age < -5||age>maxAgeSeconds)throw Error(`Hardware diagnostics are stale or invalid (${age.toFixed(1)} seconds old)`);
  for(const field of ['frames','failures','dialFailures','lifetimeFailures','dialLifetimeFailures','inputErrors']) {
    if(!Number.isFinite(current.hardware[field])||current.hardware[field]<initial.hardware[field])throw Error(`Hardware ${field} counter missing or reset`);
  }
  for(const field of ['keypadConnected','rollerConnected','knobsConnected','screenDialConnected']) {
    if(typeof initial.hardware[field]!=='boolean'||typeof current.hardware[field]!=='boolean')throw Error(`Hardware ${field} state is missing`);
    if(current.hardware[field]!==initial.hardware[field])throw Error(`Hardware ${field} connection changed during measurement`);
  }
}
export function summarize(initial,samples) {
  const last=samples.at(-1);if(!last)return null;
  const profiles=Object.fromEntries(Object.keys(initial.processes).map(name=>{
    const rows=[initial,...samples].map(row=>row.processes[name]);
    return[name,{averageCPUPercent:100*(last.processes[name].cpuSeconds-initial.processes[name].cpuSeconds)/last.elapsedSeconds,
      initialRSSKB:rows[0].rssKB,finalRSSKB:rows.at(-1).rssKB,peakRSSKB:Math.max(...rows.map(row=>row.rssKB)),
      memoryGrowthKB:rows.at(-1).rssKB-rows[0].rssKB}];
  }));
  const transfers=Object.fromEntries(['frames','failures','dialFailures','lifetimeFailures','dialLifetimeFailures','inputErrors'].map(field=>[field,last.hardware[field]-initial.hardware[field]]));
  return {profiles,liveProductCPUPercent:profiles.gui.averageCPUPercent+profiles.service.averageCPUPercent,transfers,
    maximumDiagnosticsAgeSeconds:Math.max(...[initial,...samples].map(row=>row.observedAt-row.hardware.updatedAt)),
    zeroNewTransferFailures:['failures','dialFailures','lifetimeFailures','dialLifetimeFailures','inputErrors'].every(field=>transfers[field]===0)};
}

async function main() {
  if(process.argv.includes('--help')) {
    console.log('Usage: node scripts/benchmark-native.mjs [--seconds 10..3600] [--live-only]\n--live-only measures the installed GUI and service without opening demo windows. Keep Agent Deck running for the requested duration.');
    return;
  }
  const root=path.resolve(import.meta.dirname,'..');
  const index=process.argv.indexOf('--seconds');
  const duration=index<0?300:Number(process.argv[index+1]);
  const liveOnly=process.argv.includes('--live-only');
  if(!Number.isInteger(duration)||duration<10||duration>3600)throw Error('--seconds must be an integer between 10 and 3600; release measurements require 300 seconds.');
  const app=path.join(os.homedir(),'Applications/Agent Deck.app');
  execFileSync('codesign',['--verify','--deep','--strict',app]);
  const info=JSON.parse(execFileSync('plutil',['-convert','json','-o','-',path.join(app,'Contents/Info.plist')],{encoding:'utf8'}));
  const runtime=path.join(os.homedir(),'Library/Caches/AgentDeck');
  const readJSON=name=>JSON.parse(fs.readFileSync(path.join(runtime,name),'utf8'));
  const gui=readJSON('window-health.json').pid,service=readJSON('connection.json').servicePid;
  const children=[],ownedDemos=[],ownedMarkers=new Map();
  const ownedAlive=pid=>{try{return execFileSync('ps',['-p',String(pid),'-o','args='],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).includes(ownedMarkers.get(pid));}catch{return false;}};let initial,start,failure,interrupted=false;const samples=[];
  const interrupt=()=>{interrupted=true;};
  process.on('SIGINT',interrupt);process.on('SIGTERM',interrupt);
  try {
    const launchDemo=async idle=>{
      const marker='deck-benchmark-'+randomUUID();
      // SwiftUI app instances require LaunchServices' new-instance configuration.
      const child=spawn('/usr/bin/open',['-n','-W',app,'--args','--demo',...(idle?['--demo-idle']:[]),'--benchmark-instance',marker],{stdio:'ignore'});
      children.push(child);child.on('error',error=>{failure=error.message;});
      for(let i=0;i<100;i++) {
        if(failure)throw Error(failure);
        const rows=execFileSync('ps',['-axo','pid=,args='],{encoding:'utf8'}).split('\n');
        const row=rows.find(row=>row.includes('/Contents/MacOS/AgentDeck')&&row.includes(marker));
        if(row) {const pid=Number(row.trim().split(/\s+/)[0]);ownedDemos.push(pid);ownedMarkers.set(pid,marker);return pid;}
        if(child.exitCode!==null)throw Error(`LaunchServices demo launch exited (${child.exitCode}) before publishing a process`);
        await delay(100);
      }
      throw Error('LaunchServices did not publish an owned demo within 10 seconds');
    };
    const pids=liveOnly?{gui,service}:{activeDemo:await launchDemo(false),idleDemo:await launchDemo(true),gui,service};
    const sample=()=>{
      if(failure)throw Error(failure);
      // The LaunchServices waiter may exit independently; sample the actual marked app PID.
      if(readJSON('window-health.json').pid!==gui||readJSON('connection.json').servicePid!==service)throw Error('Installed GUI or service restarted during measurement');
      const processes=Object.fromEntries(Object.entries(pids).map(([name,pid])=>{
        if(!Number.isInteger(pid)||pid<=0)throw Error(`${name} PID is invalid`);
        let value;
        try{value=execFileSync('ps',['-p',String(pid),'-o','time=,rss=,lstart='],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim().split(/\s+/);}
        catch{throw Error(`${name} (${pid}) is no longer running`);}
        if(value.length<7)throw Error(`${name} process metrics unavailable`);
        return[name,{pid,identity:value.slice(2).join(' '),cpuSeconds:parseCPUTime(value[0]),rssKB:Number(value[1])}];
      }));
      const hardware=readJSON('masterhub-diagnostics.json');
      return{elapsedSeconds:start?(performance.now()-start)/1000:0,observedAt:Date.now()/1000,processes,hardware:{
        page:hardware.surfacePage,frames:hardware.displayFrames,failures:hardware.displayFailures,dialFailures:hardware.screenDialDisplayFailures,
        lifetimeFailures:hardware.lifetimeDisplayFailures,dialLifetimeFailures:hardware.screenDialLifetimeDisplayFailures,updatedAt:hardware.updatedAt,
        keypadConnected:hardware.keypadConnected,rollerConnected:hardware.rollerConnected,knobsConnected:hardware.knobsConnected,
        screenDialConnected:hardware.screenDialConnected,inputErrors:hardware.inputErrors}};
    };
    await delay(5000);initial=sample();validateObservation(initial,initial);start=performance.now();
    for(let elapsed=0;elapsed<duration;) {
      const interval=Math.min(30,duration-elapsed);
      for(let seconds=0;seconds<interval&&!interrupted;seconds++)await delay(1000);
      if(interrupted)throw Error('Measurement interrupted');
      const current=sample();samples.push(current);validateObservation(initial,current);
      elapsed=Math.min(duration,(performance.now()-start)/1000);
      console.log(`Measured ${elapsed.toFixed(0)}/${duration} seconds; ${Object.keys(pids).length} processes live, diagnostics ${(current.observedAt-current.hardware.updatedAt).toFixed(1)} seconds old.`);
    }
  } catch(error) {failure=error.message;}
  finally {
    process.removeListener('SIGINT',interrupt);process.removeListener('SIGTERM',interrupt);
    for(const pid of ownedDemos) {
      try {
        if(!ownedAlive(pid))continue;
        process.kill(pid,'SIGTERM');
        for(let i=0;i<20&&ownedAlive(pid);i++)await delay(100);
        if(ownedAlive(pid)){process.kill(pid,'SIGKILL');await delay(100);}
      }catch(error){if(error.code!=='ESRCH')failure??=error.message;}
    }
    for(const child of children) {
      if(child.exitCode!==null||child.signalCode!==null)continue;
      child.kill('SIGTERM');
      for(let i=0;i<20&&child.exitCode===null&&child.signalCode===null;i++)await delay(100);
      if(child.exitCode===null&&child.signalCode===null){child.kill('SIGKILL');await new Promise(resolve=>child.once('exit',resolve));}
    }
  }
  const summary=initial?summarize(initial,samples):null;
  const report={version:info.CFBundleShortVersionString,build:info.CFBundleVersion,macOS:execFileSync('sw_vers',['-productVersion'],{encoding:'utf8'}).trim(),
    requestedSeconds:duration,durationSeconds:samples.at(-1)?.elapsedSeconds??0,complete:!failure&&samples.at(-1)?.elapsedSeconds>=duration,
    scope:liveOnly?'Read-only installed GUI/service diagnostics; no demo windows, physical input, unplug, sleep, or real-agent commands.':'Concurrent isolated active/idle demos and read-only installed GUI/service diagnostics. No physical input, unplug, sleep, or real-agent commands.',
    mode:liveOnly?'live-only':'live-and-demos',
    failure:failure??null,...summary,fullDuration:!failure&&samples.at(-1)?.elapsedSeconds>=300,initial,samples,
    ownedDemosCleanedUp:ownedDemos.every(pid=>!ownedAlive(pid))&&children.every(child=>child.exitCode!==null||child.signalCode!==null)};
  const directory=path.join(root,'dist/benchmarks');fs.mkdirSync(directory,{recursive:true});
  const output=path.join(directory,`${info.CFBundleShortVersionString}-${Date.now()}.json`);fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
  console.log(JSON.stringify({output,...summary,complete:report.complete,fullDuration:report.fullDuration,failure:report.failure,ownedDemosCleanedUp:report.ownedDemosCleanedUp},null,2));
  if(failure||!report.zeroNewTransferFailures)process.exitCode=1;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href)await main();
