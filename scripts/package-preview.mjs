#!/usr/bin/env node
// Public candidate packaging only. Verification must pass before any archive is produced.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..');
const option=name=>{const i=process.argv.indexOf(name);if(i<0)return undefined;const value=process.argv[i+1];if(!value||value.startsWith('--'))throw Error(`${name} requires a value.`);return value;};
const app=path.resolve(option('--app')||path.join(root,'dist/Agent Deck.app'));
const output=option('--output-dir');
execFileSync(process.execPath,[path.join(root,'scripts/verify-native-release.mjs'),'--public','--app',app],{stdio:'inherit'});
const info=JSON.parse(execFileSync('plutil',['-convert','json','-o','-',path.join(app,'Contents/Info.plist')],{encoding:'utf8'}));
const version=String(info.CFBundleShortVersionString);
if(!/^[0-9]+(?:\.[0-9]+){1,3}$/.test(version))throw Error('Invalid app version');
const directory=output?path.resolve(output):path.join(root,'dist','releases',version);fs.mkdirSync(directory,{recursive:true});
const artifact=path.join(directory,`AgentDeck-${version}-masterhub-preview-universal.zip`);
if(fs.existsSync(artifact))throw Error('Versioned artifact already exists; choose a new version instead of overwriting it.');
execFileSync('ditto',['-c','-k','--sequesterRsrc','--keepParent',app,artifact],{stdio:'inherit'});
const digest=crypto.createHash('sha256').update(fs.readFileSync(artifact)).digest('hex');
fs.writeFileSync(artifact+'.sha256',`${digest}  ${path.basename(artifact)}\n`,{flag:'wx'});
console.log(`Prepared signed/notarized candidate: ${artifact}\nNot published.`);
