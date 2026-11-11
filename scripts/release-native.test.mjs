import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {createPlan,parseOptions,prepareRelease} from './release-native.mjs';

function fixture(t){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'agent-deck-release-test-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const git=args=>execFileSync('git',args,{cwd:root,encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
  git(['init']);git(['config','user.name','Release Test']);git(['config','user.email','release-test@example.invalid']);
  fs.mkdirSync(path.join(root,'native'));fs.mkdirSync(path.join(root,'scripts'));fs.mkdirSync(path.join(root,'daemon'));
  fs.writeFileSync(path.join(root,'native/Info.plist'),'<plist><dict><key>CFBundleShortVersionString</key><string>0.3.6</string><key>CFBundleVersion</key><string>10</string></dict></plist>');
  fs.writeFileSync(path.join(root,'tracked.txt'),'committed source\n');
  fs.writeFileSync(path.join(root,'daemon/fixture.test.mjs'),'// fixture\n');
  fs.writeFileSync(path.join(root,'scripts/build-native.mjs'),'// committed build script\n');
  git(['add','.']);git(['commit','-m','Fixture source']);
  const commit=git(['rev-parse','HEAD']);
  const env={AGENT_DECK_SIGN_IDENTITY:'Developer ID Application: Local Test',AGENT_DECK_UPDATE_FEED:'https://updates.example.invalid/appcast.xml',AGENT_DECK_UPDATE_PUBLIC_KEY:Buffer.alloc(32,7).toString('base64')};
  const options={commit,'artifact-url':'https://updates.example.invalid/AgentDeck-0.3.6-masterhub-preview-universal.zip','output-dir':path.join(root,'output')};
  return {root,git,commit,env,options,plan:()=>createPlan({root,options,env,home:root})};
}

test('release preflight rejects dirty, staged, and untracked source',t=>{
  const f=fixture(t);
  fs.writeFileSync(path.join(f.root,'tracked.txt'),'modified');
  assert.throws(f.plan,/must be clean/);
  f.git(['add','tracked.txt']);assert.throws(f.plan,/must be clean/);
  f.git(['restore','--staged','tracked.txt']);f.git(['restore','tracked.txt']);
  fs.writeFileSync(path.join(f.root,'untracked.txt'),'not committed');
  assert.throws(f.plan,/must be clean/);
  assert(!fs.existsSync(f.options['output-dir']));
});

test('preflight pins the full source commit and refuses unsafe update destinations or output reuse',t=>{
  const f=fixture(t);
  f.options.commit=f.commit.slice(0,12);assert.throws(f.plan,/full current HEAD/);f.options.commit=f.commit;
  f.options['artifact-url']='http://updates.example.invalid/AgentDeck-0.3.6-masterhub-preview-universal.zip';assert.throws(f.plan,/HTTPS/);
  f.options['artifact-url']='https://user:password@updates.example.invalid/AgentDeck-0.3.6-masterhub-preview-universal.zip';assert.throws(f.plan,/credentials/);
  f.options['artifact-url']='https://updates.example.invalid/wrong.zip';assert.throws(f.plan,/must name AgentDeck-0.3.6/);
  f.options['artifact-url']='https://updates.example.invalid/AgentDeck-0.3.6-masterhub-preview-universal.zip';
  const plan=f.plan();assert.equal(plan.commit,f.commit);assert.equal(plan.build,'10');
  fs.mkdirSync(plan.output);assert.throws(f.plan,/output already exists/);
});

function fakePipeline(f,{failAt,signature=Buffer.alloc(64,8).toString('base64')}={}){
  const calls=[];
  const run=(command,args,options)=>{
    if(command==='git'||command==='tar')return execFileSync(command,args,options);
    const script=path.basename(args[0]||'');calls.push({command,args});
    if(script===failAt)throw Error(`deliberate failure: ${script}`);
    if(script==='build-native.mjs'){
      const directory=args[args.indexOf('--output-dir')+1];
      fs.mkdirSync(path.join(directory,'Agent Deck.app'),{recursive:true});
    }
    if(script==='notarize-native.mjs'){
      const directory=args[args.indexOf('--output-dir')+1];fs.mkdirSync(directory,{recursive:true});
      fs.writeFileSync(path.join(directory,'notarization.json'),JSON.stringify({id:'test-submission',status:'Accepted'}));
    }
    if(script==='package-preview.mjs'){
      const directory=args[args.indexOf('--output-dir')+1];fs.mkdirSync(directory,{recursive:true});
      fs.writeFileSync(path.join(directory,'AgentDeck-0.3.6-masterhub-preview-universal.zip'),'fixture signed archive');
      fs.writeFileSync(path.join(directory,'AgentDeck-0.3.6-masterhub-preview-universal.zip.sha256'),'fixture checksum');
    }
    if(script==='prepare-update-feed.mjs'){
      const directory=args[args.indexOf('--output-dir')+1];fs.writeFileSync(path.join(directory,'appcast.xml'),'<signed-feed/>');
    }
    if(path.basename(command)==='sign_update'&&args.includes('-p'))return signature;
    return '';
  };
  return {run,calls};
}

test('pipeline builds archived commit despite later edits, signs hash-bound provenance, never installs/publishes',t=>{
  const f=fixture(t),plan=f.plan(),pipeline=fakePipeline(f);
  fs.writeFileSync(path.join(f.root,'tracked.txt'),'later working tree edits');
  const result=prepareRelease({root:f.root,plan,env:f.env,run:pipeline.run});
  assert.equal(fs.readFileSync(path.join(plan.output,'source/tracked.txt'),'utf8'),'committed source\n');
  const provenance=JSON.parse(fs.readFileSync(result.provenancePath,'utf8'));
  assert.equal(provenance.source.commit,f.commit);assert.equal(provenance.source.clean,true);
  assert.match(provenance.source.archiveSha256,/^[a-f0-9]{64}$/);
  assert.equal(provenance.notarization.status,'Accepted');assert.equal(provenance.artifacts.length,3);
  assert(provenance.artifacts.every(artifact=>/^[a-f0-9]{64}$/.test(artifact.sha256)));
  assert.equal(provenance.installed,false);assert.equal(provenance.published,false);
  assert(fs.existsSync(result.provenancePath+'.ed25519'));assert(fs.existsSync(result.provenancePath+'.sha256'));
  assert(pipeline.calls.some(call=>call.command==='swift'&&call.args[0]==='test'));
  assert(!pipeline.calls.some(call=>call.args.includes('--install')||call.command==='gh'));
  assert.throws(()=>prepareRelease({root:f.root,plan,env:f.env,run:pipeline.run}),/EEXIST/);
});

test('failed notarization stops packaging and preserves failure evidence without credential contents',t=>{
  const f=fixture(t),plan=f.plan(),pipeline=fakePipeline(f,{failAt:'notarize-native.mjs'});
  assert.throws(()=>prepareRelease({root:f.root,plan,env:f.env,run:pipeline.run}),/deliberate failure/);
  assert(!pipeline.calls.some(call=>path.basename(call.args[0]||'')==='package-preview.mjs'));
  const evidence=fs.readFileSync(path.join(plan.output,'release-failure.json'),'utf8');
  assert.equal(JSON.parse(evidence).commit,f.commit);assert(!evidence.includes(f.env.AGENT_DECK_SIGN_IDENTITY));
  assert(!fs.existsSync(path.join(plan.output,'release/build-provenance.json')));
});

test('bad provenance signature never produces a completed signature record',t=>{
  const f=fixture(t),plan=f.plan(),pipeline=fakePipeline(f,{signature:'invalid'});
  assert.throws(()=>prepareRelease({root:f.root,plan,env:f.env,run:pipeline.run}),/valid Ed25519 signature/);
  assert(!fs.existsSync(path.join(plan.output,'release/build-provenance.json.ed25519')));
  assert(fs.existsSync(path.join(plan.output,'release-failure.json')));
});

test('CLI accepts only bounded release options and rejects missing or duplicate values',()=>{
  assert.throws(()=>parseOptions(['--install']),/Unknown argument/);
  assert.throws(()=>parseOptions(['--commit']),/requires a value/);
  assert.throws(()=>parseOptions(['--commit','abc','--commit','def']),/Duplicate/);
  assert.equal(parseOptions(['--plan','--commit','abc']).plan,true);
});
