#!/usr/bin/env node
// Prepare a signed Sparkle feed locally. Never uploads or publishes anything.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..');
const option=name=>{const i=process.argv.indexOf(name);if(i<0)return undefined;const value=process.argv[i+1];if(!value||value.startsWith('--'))throw Error(`${name} requires a value.`);return value;};
const account=option('--key-account')||'com.aiagentdeck.updates';
const artifactURL=new URL(option('--artifact-url')||'https://invalid.example/');
assert(artifactURL.protocol==='https:'&&!artifactURL.username&&!artifactURL.password&&artifactURL.hostname!=='invalid.example','Supply --artifact-url with the intended public HTTPS ZIP URL.');
const app=path.resolve(option('--app')||path.join(root,'dist/Agent Deck.app'));
execFileSync(process.execPath,[path.join(root,'scripts/verify-native-release.mjs'),'--public','--app',app],{stdio:'inherit'});
const info=JSON.parse(execFileSync('plutil',['-convert','json','-o','-',path.join(app,'Contents/Info.plist')],{encoding:'utf8'}));
const name=`AgentDeck-${info.CFBundleShortVersionString}-masterhub-preview-universal.zip`;
const directory=path.resolve(option('--output-dir')||path.join(root,'dist/releases',String(info.CFBundleShortVersionString)));
const artifact=path.join(directory,name);
assert(fs.existsSync(artifact),'Run package-preview.mjs first.');
assert(path.posix.basename(artifactURL.pathname)===name,'Artifact URL must name the exact versioned ZIP.');
const tools=[path.join(root,'native/.build/artifacts/sparkle/Sparkle/bin'),path.join(root,'native/.build/universal/artifacts/sparkle/Sparkle/bin')].find(value=>fs.existsSync(path.join(value,'sign_update')));
assert(tools,'Sparkle update signing tools are missing; build the app first.');
const publicKey=execFileSync(path.join(tools,'generate_keys'),['--account',account,'-p'],{encoding:'utf8'}).trim();
assert.equal(publicKey,info.SUPublicEDKey,'Update key does not match the public key embedded in the app.');
const output=path.join(directory,'appcast.xml');
assert(!fs.existsSync(output),'An appcast already exists; preserve it and prepare a separate release directory.');
const signature=execFileSync(path.join(tools,'sign_update'),['--account',account,'-p',artifact],{encoding:'utf8'}).trim();
assert.equal(Buffer.from(signature,'base64').length,64,'Invalid Ed25519 update signature.');
execFileSync(path.join(tools,'sign_update'),['--account',account,'--verify',artifact,signature],{stdio:'inherit'});
const escape=value=>String(value).replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[char]));
const xml=`<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Agent Deck updates</title><link>${escape(info.SUFeedURL)}</link>
<item><title>Agent Deck ${escape(info.CFBundleShortVersionString)} — MasterHUB preview</title>
<sparkle:minimumSystemVersion>${escape(info.LSMinimumSystemVersion)}</sparkle:minimumSystemVersion>
<enclosure url="${escape(artifactURL.href)}" sparkle:version="${escape(info.CFBundleVersion)}" sparkle:shortVersionString="${escape(info.CFBundleShortVersionString)}" sparkle:edSignature="${escape(signature)}" length="${fs.statSync(artifact).size}" type="application/octet-stream" />
</item></channel></rss>
`;
fs.writeFileSync(output,xml,{flag:'wx'});
try {
  execFileSync(path.join(tools,'sign_update'),['--account',account,output],{stdio:'inherit'});
  execFileSync(path.join(tools,'sign_update'),['--account',account,'--verify',output],{stdio:'inherit'});
} catch(error) {
  throw Error('Feed preparation failed. Preserve the output for inspection before retrying.',{cause:error});
}
console.log('Prepared signed appcast:',output,'\nNot published. Verify public feed and download availability after publication.');
