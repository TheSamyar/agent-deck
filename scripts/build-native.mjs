#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
const root=path.resolve(import.meta.dirname,'..');
const outputIndex=process.argv.indexOf('--output-dir');
if(outputIndex>=0&&(!process.argv[outputIndex+1]||process.argv[outputIndex+1].startsWith('--')))throw Error('--output-dir requires a directory.');
const destination=outputIndex>=0?path.resolve(process.argv[outputIndex+1]):path.join(root,'dist');
function checkIsolatedOutput(){
  if(outputIndex>=0&&fs.existsSync(path.join(destination,'Agent Deck.app')))throw Error('Isolated output already contains Agent Deck.app. Choose a new --output-dir; existing candidates are never replaced.');
}
checkIsolatedOutput();
// Serialize packaging/install as well as compilation; SwiftPM does not lock app archives.
const buildLock=path.join(root,'dist','.native-build.lock');
fs.mkdirSync(path.dirname(buildLock),{recursive:true});
const lockOwner=path.join(buildLock,'pid');
const lockDeadline=Date.now()+300000;
for(;;){
  try{fs.mkdirSync(buildLock);fs.writeFileSync(lockOwner,String(process.pid));break;}
  catch(error){
    if(error.code!=='EEXIST')throw error;
    try{
      const owner=Number(fs.readFileSync(lockOwner,'utf8'));
      if(Number.isInteger(owner)&&owner>0){
        try{process.kill(owner,0);}catch(probe){
          if(probe.code==='ESRCH'){fs.unlinkSync(lockOwner);fs.rmdirSync(buildLock);continue;}
        }
      }
    }catch{}
    if(Date.now()>lockDeadline)throw Error('Another native build is still packaging. Retry after it finishes.');
    await delay(500);
  }
}
process.on('exit',()=>{
  try{if(fs.readFileSync(lockOwner,'utf8')===String(process.pid)){fs.unlinkSync(lockOwner);fs.rmdirSync(buildLock);}}catch{}
});
// Another build may have created this candidate while we waited for the lock.
checkIsolatedOutput();

const universal=process.argv.includes('--universal');
const release=process.argv.includes('--release');
const install=process.argv.includes('--install');
const configuration=release?'release':'debug';
const args=['build','--package-path',path.join(root,'native'),'-c',configuration];
// Keep universal products separate from normal builds/tests, which replace thin binaries.
if(universal)args.push('--scratch-path',path.join(root,'native/.build/universal'),'--arch','arm64','--arch','x86_64');
execFileSync('swift',args,{stdio:'inherit'});
const bin=execFileSync('swift',[...args,'--show-bin-path'],{encoding:'utf8'}).trim();
if(universal)for(const name of ['AgentDeck','deck-service','deck-hook','install-hooks']){
  const architectures=execFileSync('lipo',['-archs',path.join(bin,name)],{encoding:'utf8'}).trim().split(/\s+/);
  if(!architectures.includes('arm64')||!architectures.includes('x86_64'))throw Error(`Universal build missing an architecture: ${name}. Do not run other Swift builds concurrently.`);
}
fs.mkdirSync(destination,{recursive:true});
fs.writeFileSync(path.join(destination,'.metadata_never_index'),'');
const finalApp=path.join(destination,'Agent Deck.app');
const stage=fs.mkdtempSync(path.join(destination,'.native-'));
const app=path.join(stage,'Agent Deck.app');
for(const dir of ['Contents/MacOS','Contents/Resources','Contents/Library/LaunchAgents','Contents/Frameworks'])fs.mkdirSync(path.join(app,dir),{recursive:true});
fs.copyFileSync(path.join(root,'native/Info.plist'),path.join(app,'Contents/Info.plist'));
fs.cpSync(path.join(root,'native/Resources/Updates'),path.join(app,'Contents/Resources/Updates'),{recursive:true,filter:source=>!source.includes('__pycache__')&&!source.endsWith('.pyc')});
fs.cpSync(path.join(root,'native/Resources/KokoroVoice'),path.join(app,'Contents/Resources/KokoroVoice'),{recursive:true,filter:source=>!source.includes('__pycache__')});
const wakeResources=path.join(root,'native/Resources/AlfredWake');
for(const name of ['worker.py','setup.py','requirements.txt','model-manifest.json']) {
  if(!fs.existsSync(path.join(wakeResources,name)))throw Error('Missing Alfred wake resource: '+name);
}
fs.cpSync(wakeResources,path.join(app,'Contents/Resources/AlfredWake'),{recursive:true,filter:source=>!source.includes('__pycache__')&&!source.endsWith('.pyc')});
fs.cpSync(path.join(root,'browser-extension'),path.join(app,'Contents/Resources/BrowserExtension'),{recursive:true,filter:source=>!source.includes('__pycache__')});
fs.cpSync(path.join(root,'native/Resources/Jarvis'),path.join(app,'Contents/Resources/Jarvis'),{recursive:true,filter:source=>!source.includes('__pycache__')});
// Pin the shipped observation hook so subscription tasks can recognize our own hooks.
fs.copyFileSync(path.join(root,'bin/agent-hook.mjs'),path.join(app,'Contents/Resources/Jarvis/approved-agent-hook.mjs'));
fs.cpSync(path.join(root,'native/Resources/ProviderLogos'),path.join(app,'Contents/Resources/ProviderLogos'),{recursive:true});
fs.cpSync(path.join(root,'native/Resources/ProviderSculptures'),path.join(app,'Contents/Resources/ProviderSculptures'),{recursive:true});
const feed=process.env.AGENT_DECK_UPDATE_FEED,key=process.env.AGENT_DECK_UPDATE_PUBLIC_KEY;
if(Boolean(feed)!==Boolean(key))throw Error('Set both AGENT_DECK_UPDATE_FEED and AGENT_DECK_UPDATE_PUBLIC_KEY to enable signed updates.');
if(feed){if(!feed.startsWith('https://'))throw Error('Update feed must use HTTPS.');for(const [name,value] of [['SUFeedURL',feed],['SUPublicEDKey',key]])execFileSync('/usr/libexec/PlistBuddy',['-c',`Add :${name} string ${value}`,path.join(app,'Contents/Info.plist')]);}
function findFramework(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const full=path.join(dir,entry.name);if(entry.name==='Sparkle.framework')return full;if(entry.isDirectory()){const found=findFramework(full);if(found)return found;}}return null;}
const sparkle=findFramework(path.join(root,universal?'native/.build/universal/artifacts':'native/.build/artifacts'));
if(!sparkle)throw Error('Sparkle framework is missing from the resolved package artifacts.');
fs.cpSync(sparkle,path.join(app,'Contents/Frameworks/Sparkle.framework'),{recursive:true,verbatimSymlinks:true});
for(const name of ['AgentDeck','deck-hook'])fs.copyFileSync(path.join(bin,name),path.join(app,'Contents/MacOS',name));
// A distinct helper bundle prevents AppKit discovery from registering the service
// as a second foreground dashboard under the GUI's bundle identifier.
const serviceRelative='Contents/Helpers/DeckService.bundle';
const serviceBundle=path.join(app,serviceRelative);
fs.mkdirSync(path.join(serviceBundle,'Contents/MacOS'),{recursive:true});
fs.copyFileSync(path.join(bin,'deck-service'),path.join(serviceBundle,'Contents/MacOS/deck-service'));
fs.writeFileSync(path.join(serviceBundle,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.aiagentdeck.service</string><key>CFBundleName</key><string>Agent Deck Service</string><key>CFBundleExecutable</key><string>deck-service</string><key>CFBundlePackageType</key><string>BNDL</string><key>CFBundleVersion</key><string>2</string><key>LSBackgroundOnly</key><true/><key>NSAppleEventsUsageDescription</key><string>Agent Deck opens the exact project window or terminal you select.</string></dict></plist>`);
// Preserve the old executable path for tooling; all launches use the helper's real path.
fs.symlinkSync('../Helpers/DeckService.bundle/Contents/MacOS/deck-service',path.join(app,'Contents/MacOS/deck-service'));
fs.copyFileSync(path.join(bin,'install-hooks'),path.join(app,'Contents/Resources/install-hooks'));
const licenses=path.join(app,'Contents/Resources/Licenses');fs.mkdirSync(licenses,{recursive:true});
for(const [source,name] of [['LICENSE','AgentDeck.txt'],['NOTICE.md','NOTICE.md'],['docs/licenses/Sparkle.txt','Sparkle.txt']])fs.copyFileSync(path.join(root,source),path.join(licenses,name));
fs.cpSync(path.join(root,'cursor-extension'),path.join(app,'Contents/Resources/EditorExtension'),{recursive:true});
const plugin=path.join(root,'plugin/dist');
if(process.argv.includes('--require-keypad') && !fs.existsSync(path.join(plugin,'AiAgentDeckPlugin.dll')))throw Error('Release requires the compiled keypad plugin. Run node scripts/build-and-deploy.mjs first.');
if(process.argv.includes('--require-keypad') || process.argv.includes('--with-keypad')) {
  if(!fs.existsSync(path.join(plugin,'AiAgentDeckPlugin.dll')))throw Error('Build the optional vendor keypad plugin before requesting it.');
  fs.cpSync(plugin,path.join(app,'Contents/Resources/KeypadPlugin'),{recursive:true});
}
const source=`import AppKit
let image=NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
NSColor(calibratedRed:0.08,green:0.09,blue:0.11,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:0,y:0,width:1024,height:1024),xRadius:220,yRadius:220).fill()
for row in 0..<2 { for col in 0..<2 {
NSColor(calibratedWhite:0.88,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:230+col*300,y:230+row*300,width:240,height:240),xRadius:54,yRadius:54).fill()
} }
NSColor(calibratedRed:0.93,green:0.66,blue:0.25,alpha:1).setFill()
NSBezierPath(ovalIn:NSRect(x:700,y:700,width:110,height:110)).fill()
image.unlockFocus()
let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
`;
const iconScript=path.join(destination,'icon.swift');fs.writeFileSync(iconScript,source);
const icon=path.join(destination,'icon.png');execFileSync('swift',[iconScript,icon]);
const iconset=path.join(destination,'AgentDeck.iconset');fs.mkdirSync(iconset,{recursive:true});
for(const size of [16,32,128,256,512])for(const scale of [1,2])execFileSync('sips',['-z',String(size*scale),String(size*scale),icon,'--out',path.join(iconset,`icon_${size}x${size}${scale===2?'@2x':''}.png`)],{stdio:'ignore'});
execFileSync('iconutil',['-c','icns',iconset,'-o',path.join(app,'Contents/Resources/AgentDeck.icns')]);
const plist=`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>com.aiagentdeck.service</string><key>BundleProgram</key><string>Contents/Helpers/DeckService.bundle/Contents/MacOS/deck-service</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>`;
fs.writeFileSync(path.join(app,'Contents/Library/LaunchAgents/com.aiagentdeck.service.plist'),plist);
// Remember the explicitly chosen certificate so subsequent local builds retain TCC identity.
const signingConfig=path.join(process.env.HOME,'Library/Application Support/Agent Deck/build-signing-identity.txt');
const savedIdentity=fs.existsSync(signingConfig)?fs.readFileSync(signingConfig,'utf8').trim():'';
const identity=process.env.AGENT_DECK_SIGN_IDENTITY||savedIdentity||'-';
const entitlements=path.join(destination,'Entitlements.plist');fs.copyFileSync(path.join(root,'native/Entitlements.plist'),entitlements);
if(identity==='-')execFileSync('/usr/libexec/PlistBuddy',['-c','Add :com.apple.security.cs.disable-library-validation bool true',entitlements]);
const timestamp=identity==='-'?[]:['--timestamp'];
const sparkleBundle=path.join(app,'Contents/Frameworks/Sparkle.framework');
// Sign nested executables inside out; --deep verification does not sign them.
for(const relative of ['Versions/B/Autoupdate','Versions/B/Updater.app','Versions/B/XPCServices/Downloader.xpc','Versions/B/XPCServices/Installer.xpc']) {
  const target=path.join(sparkleBundle,relative);
  if(!fs.existsSync(target))throw Error('Missing Sparkle signing target: '+relative);
  execFileSync('codesign',['--force','--options','runtime','--preserve-metadata=entitlements',...timestamp,'--sign',identity,target],{stdio:'inherit'});
}
execFileSync('codesign',['--force','--options','runtime',...timestamp,'--sign',identity,sparkleBundle],{stdio:'inherit'});
execFileSync('codesign',['--force','--options','runtime','--entitlements',entitlements,...timestamp,'--sign',identity,serviceBundle],{stdio:'inherit'});
for(const executable of ['Contents/MacOS/deck-hook','Contents/Resources/install-hooks'])execFileSync('codesign',['--force','--options','runtime','--entitlements',entitlements,...timestamp,'--sign',identity,path.join(app,executable)],{stdio:'inherit'});
execFileSync('codesign',['--force','--options','runtime','--entitlements',entitlements,...timestamp,'--sign',identity,app],{stdio:'inherit'});
execFileSync('codesign',['--verify','--deep','--strict',app],{stdio:'inherit'});
// Rollbacks are archives, never additional launchable app bundles.
function archivePrevious(bundle, directory) {
  fs.mkdirSync(directory,{recursive:true});
  const archive=path.join(directory,`Agent-Deck-${Date.now()}.zip`);
  execFileSync('/usr/bin/ditto',['-c','-k','--sequesterRsrc','--keepParent',bundle,archive]);
  // Only remove the old bundle after ditto has successfully preserved it.
  fs.rmSync(bundle,{recursive:true});
}
checkIsolatedOutput();
if(fs.existsSync(finalApp))archivePrevious(finalApp,path.join(destination,'previous'));
fs.renameSync(app,finalApp);
if(install){
  const target=path.join(process.env.HOME,'Applications','Agent Deck.app');fs.mkdirSync(path.dirname(target),{recursive:true});
  const staging=target+'.installing-'+Date.now();fs.cpSync(finalApp,staging,{recursive:true,verbatimSymlinks:true});
  execFileSync('codesign',['--verify','--deep','--strict',staging],{stdio:'inherit'});
  if(fs.existsSync(target))archivePrevious(target,path.join(process.env.HOME,'Library/Caches/AgentDeck/PreviousApplications'));
  fs.renameSync(staging,target);console.log('Installed:',target);
}
if(install && identity!=='-'){
  fs.mkdirSync(path.dirname(signingConfig),{recursive:true});
  fs.writeFileSync(signingConfig,identity+'\n',{mode:0o600});
}
console.log('Built:',finalApp);console.log(identity==='-'?'Local development signature. Public distribution requires a Developer ID certificate and notarization.':'Certificate signing complete; public distribution requires Developer ID signing and notarization.');
