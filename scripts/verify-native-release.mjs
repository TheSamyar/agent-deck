#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..');
const appIndex=process.argv.indexOf('--app');
if(appIndex>=0&&(!process.argv[appIndex+1]||process.argv[appIndex+1].startsWith('--')))throw Error('--app requires a bundle path.');
const app=appIndex>=0?path.resolve(process.argv[appIndex+1]):path.join(root,'dist/Agent Deck.app');
const publicRelease=process.argv.includes('--public');
for(const name of ['worker.py','setup.py','requirements.txt','model-manifest.json'])assert(fs.existsSync(path.join(app,'Contents/Resources/AlfredWake',name)),`Missing Alfred wake resource ${name}`);
const wakeManifest=JSON.parse(fs.readFileSync(path.join(app,'Contents/Resources/AlfredWake/model-manifest.json'),'utf8'));
assert.equal(wakeManifest.version,1,'Unsupported Alfred wake manifest');
assert.equal(wakeManifest.verification_phrase,'Hey Alfred','Wake resources must describe Alfred');
assert.equal(wakeManifest.files.length,4,'Wake manifest must include all inference assets');
for(const file of wakeManifest.files){assert.equal(path.basename(file.name),file.name,'Wake assets must use plain filenames');assert(/^[a-f0-9]{64}$/.test(file.sha256),'Wake assets must have pinned SHA256 hashes');assert(file.url.startsWith('https://'),'Wake downloads require HTTPS');}
const run=(command,args)=>execFileSync(command,args,{encoding:'utf8',stdio:['ignore','pipe','pipe']});
for(const executable of ['AgentDeck','deck-service','deck-hook']){
  const target=path.join(app,'Contents/MacOS',executable);
  const architecture=run('lipo',['-archs',target]);assert(architecture.includes('arm64')&&architecture.includes('x86_64'),`${executable} must include both architectures`);
  const load=run('otool',['-l',target]);assert(![...load.matchAll(/minos ([\d.]+)/g)].some(m=>Number(m[1].split('.')[0])>14),`${executable} requires a macOS version newer than 14`);
  const links=run('otool',['-L',target]).split('\n').filter(line=>line.startsWith('\t')).join('\n');assert(!links.includes('/Users/')&&!links.includes('/opt/homebrew/'),`${executable} links to development-machine libraries`);
}
for(const relative of ['Contents/Resources/Licenses/AgentDeck.txt','Contents/Resources/Licenses/NOTICE.md','Contents/Resources/Licenses/Sparkle.txt','Contents/Resources/install-hooks','Contents/Resources/EditorExtension/package.json','Contents/Resources/AgentDeck.icns','Contents/Frameworks/Sparkle.framework'])assert(fs.existsSync(path.join(app,relative)),`Missing ${relative}`);
const helper=path.join(app,'Contents/Helpers/DeckService.bundle');
const helperInfo=JSON.parse(run('plutil',['-convert','json','-o','-',path.join(helper,'Contents/Info.plist')]));
assert.equal(helperInfo.CFBundleIdentifier,'com.aiagentdeck.service','Service must not reuse the dashboard identity');
assert.equal(helperInfo.LSBackgroundOnly,true,'Service must be background-only');
assert.equal(fs.realpathSync(path.join(app,'Contents/MacOS/deck-service')),fs.realpathSync(path.join(helper,'Contents/MacOS/deck-service')),'Legacy service entry must resolve to the bundled helper');
try{run('codesign',['--verify','--deep','--strict',app]);}
catch(error){
  console.error(`FAIL: package signature verification did not pass: ${app}\n${String(error.stderr||error.message).trim()}\nRecovery: restricted automation can block macOS trust services. Repeat this read-only check with trust-service access before concluding the bundle was modified. If it still fails, build a fresh candidate with node scripts/build-native.mjs --universal --release --output-dir <new-directory> and verify it with --app. Do not publish a failing candidate.`);
  process.exit(1);
}
if(publicRelease){
  if(process.argv.includes('--require-keypad')) assert(fs.existsSync(path.join(app,'Contents/Resources/KeypadPlugin/AiAgentDeckPlugin.dll')),'Vendor-device builds must bundle the keypad plugin.');
  const result=execFileSync('codesign',['-dv','--verbose=4',app],{encoding:'utf8',stdio:['ignore','pipe','pipe']});void result;
  // codesign writes signing metadata to stderr.
  const details=await import('node:child_process').then(({spawnSync})=>spawnSync('codesign',['-dv','--verbose=4',app],{encoding:'utf8'}).stderr);
  assert(details.includes('Authority=Developer ID Application:'),'Public builds require Developer ID Application signing.');
  const expectedAuthority=details.split('\n').find(line=>line.startsWith('Authority='));
  for(const relative of ['Contents/Frameworks/Sparkle.framework','Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate','Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app','Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc','Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc','Contents/Helpers/DeckService.bundle','Contents/MacOS/deck-hook','Contents/Resources/install-hooks']) {
    const signed=await import('node:child_process').then(({spawnSync})=>spawnSync('codesign',['-dv','--verbose=4',path.join(app,relative)],{encoding:'utf8'}));
    assert.equal(signed.status,0,`Cannot inspect nested signature: ${relative}`);
    assert(signed.stderr.split('\n').includes(expectedAuthority),`Nested code must use the same Developer ID: ${relative}`);
    assert(signed.stderr.includes('Timestamp='),`Nested code needs a secure timestamp: ${relative}`);
    assert(/flags=.*runtime/.test(signed.stderr),`Nested code needs hardened runtime: ${relative}`);
  }

  try{run('xcrun',['stapler','validate',app]);}
  catch(error){
    console.error(`FAIL: notarization-ticket validation did not pass: ${app}\n${String(error.stderr||error.stdout||error.message).trim()}\nRecovery: this candidate cannot pass the public release gate until notarization and stapling are complete. Review the exact candidate and authorized notarization process; this verifier never uploads or changes it.`);
    process.exit(1);
  }
  run('spctl',['--assess','--type','execute',app]);
  const plist=run('plutil',['-convert','json','-o','-',path.join(app,'Contents/Info.plist')]);const info=JSON.parse(plist);
  assert(info.SUFeedURL?.startsWith('https://'),'Public builds need an HTTPS update feed.');assert.equal(Buffer.from(info.SUPublicEDKey||'','base64').length,32,'Public builds need a valid Ed25519 update key.');
}
console.log(publicRelease?'PASS: universal, portable, signed, notarized public package with signed-update configuration.':'PASS: universal, portable, internally signed local package. Public signing/notarization and update-feed checks require --public.');
