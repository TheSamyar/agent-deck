#!/usr/bin/env node
import {execFileSync,spawnSync} from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
const root=path.resolve(import.meta.dirname,'..');
const option=name=>{const i=process.argv.indexOf(name);if(i<0)return undefined;const value=process.argv[i+1];if(!value||value.startsWith('--'))throw Error(`${name} requires a value.`);return value;};
const app=path.resolve(option('--app')||path.join(root,'dist/Agent Deck.app'));
const directory=path.resolve(option('--output-dir')||path.join(root,'dist'));
const zip=path.join(directory,'Agent-Deck.zip');
if(process.argv.includes('--output-dir')&&fs.existsSync(zip))throw Error('Notarization output already exists; choose a new directory.');
fs.mkdirSync(directory,{recursive:true});
if(!process.env.AGENT_DECK_NOTARY_PROFILE||!process.env.AGENT_DECK_SIGN_IDENTITY)throw Error('Set AGENT_DECK_SIGN_IDENTITY and AGENT_DECK_NOTARY_PROFILE to your Developer ID identity and stored notarytool profile.');
execFileSync('codesign',['--verify','--deep','--strict',app],{stdio:'inherit'});
const metadata=spawnSync('codesign',['-dv','--verbose=4',app],{encoding:'utf8'});
if(metadata.status!==0)throw Error('Cannot inspect candidate signing identity.');
const authority=metadata.stderr.split('\n').find(line=>line.startsWith('Authority='))?.slice('Authority='.length);
if(!authority?.startsWith('Developer ID Application:')||authority!==process.env.AGENT_DECK_SIGN_IDENTITY)throw Error('Candidate signing identity must match AGENT_DECK_SIGN_IDENTITY and be Developer ID Application. Rebuild before uploading.');
if(!metadata.stderr.includes('Timestamp='))throw Error('Candidate requires a secure signing timestamp before notarization.');

execFileSync('ditto',['-c','-k','--keepParent',app,zip],{stdio:'inherit'});
console.log('Submitting signed candidate; waiting for Apple processing.');
const submission=JSON.parse(execFileSync('xcrun',['notarytool','submit',zip,'--keychain-profile',process.env.AGENT_DECK_NOTARY_PROFILE,'--wait','--output-format','json'],{encoding:'utf8',stdio:['ignore','pipe','inherit']}));
fs.writeFileSync(path.join(directory,'notarization.json'),JSON.stringify(submission,null,2)+'\n');
if(submission.status!=='Accepted') {
  if(submission.id)execFileSync('xcrun',['notarytool','log',submission.id,'--keychain-profile',process.env.AGENT_DECK_NOTARY_PROFILE,path.join(directory,'notarization-issues.json')],{stdio:'inherit'});
  throw Error('Apple notarization status: '+submission.status+'. See '+path.join(directory,'notarization-issues.json')+'; no stapling attempted.');
}
console.log('Apple accepted submission:',submission.id);
execFileSync('xcrun',['stapler','staple',app],{stdio:'inherit'});
execFileSync('spctl',['--assess','--type','execute','--verbose',app],{stdio:'inherit'});
execFileSync('ditto',['-c','-k','--keepParent',app,zip],{stdio:'inherit'});
console.log('Notarized and verified:',zip);
