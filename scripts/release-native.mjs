#!/usr/bin/env node
// Local release preparation only. Private keys stay in the Mac's Keychain.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const repository=path.resolve(import.meta.dirname,'..');
const hash=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const git=(root,args)=>execFileSync('git',args,{cwd:root,encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
const fail=message=>{throw Error(message);};
const httpsURL=(value,label)=>{
  let url;try{url=new URL(value);}catch{fail(`${label} must be an HTTPS URL.`);}
  if(url.protocol!=='https:'||url.username||url.password||url.hash)fail(`${label} must be HTTPS without embedded credentials or a fragment.`);
  return url.href;
};

export function parseOptions(args){
  const options={};
  for(let i=0;i<args.length;i++){
    const name=args[i];
    if(name==='--plan'){options.plan=true;continue;}
    if(!['--commit','--output-dir','--artifact-url','--key-account'].includes(name))fail(`Unknown argument: ${name}`);
    const value=args[++i];
    if(!value||value.startsWith('--'))fail(`${name} requires a value.`);
    if(options[name.slice(2)]!==undefined)fail(`Duplicate argument: ${name}`);
    options[name.slice(2)]=value;
  }
  return options;
}

export function createPlan({root=repository,options,env=process.env,home=os.homedir()}){
  const commit=git(root,['rev-parse','HEAD']);
  if(!/^[a-f0-9]{40}$/.test(options.commit||'')||options.commit!==commit)fail('--commit must name the full current HEAD commit. Check git rev-parse HEAD.');
  if(git(root,['status','--porcelain','--untracked-files=all']))fail('Release source must be clean, including staged and untracked files. Commit or move changes before preparing a release.');
  if(git(root,['ls-files','-s']).split('\n').some(line=>line.startsWith('160000 ')))fail('Submodules require explicit source capture; this release command does not support them.');
  const info=git(root,['show',`${commit}:native/Info.plist`]);
  const version=info.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([\d.]+)<\/string>/)?.[1];
  const build=info.match(/<key>CFBundleVersion<\/key>\s*<string>(\d+)<\/string>/)?.[1];
  if(!/^\d+(?:\.\d+){1,3}$/.test(version||'')||!build)fail('Source Info.plist must contain a numeric release version and build number.');
  const artifactName=`AgentDeck-${version}-masterhub-preview-universal.zip`;
  const artifactURL=httpsURL(options['artifact-url'],'--artifact-url');
  if(path.posix.basename(new URL(artifactURL).pathname)!==artifactName)fail(`--artifact-url must name ${artifactName}.`);
  const feedURL=httpsURL(env.AGENT_DECK_UPDATE_FEED,'AGENT_DECK_UPDATE_FEED');
  const publicKey=env.AGENT_DECK_UPDATE_PUBLIC_KEY||'';
  if(!/^[A-Za-z0-9+/]{43}=$/.test(publicKey)||Buffer.from(publicKey,'base64').length!==32)fail('AGENT_DECK_UPDATE_PUBLIC_KEY must contain the existing 32-byte Ed25519 public key.');
  const identityFile=path.join(home,'Library/Application Support/Agent Deck/build-signing-identity.txt');
  const identity=env.AGENT_DECK_SIGN_IDENTITY||(fs.existsSync(identityFile)?fs.readFileSync(identityFile,'utf8').trim():'');
  if(!identity.startsWith('Developer ID Application:'))fail('Configure the local Developer ID Application identity before releasing.');
  const notaryProfile=env.AGENT_DECK_NOTARY_PROFILE||'AgentDeck';
  const keyAccount=options['key-account']||'com.aiagentdeck.updates';
  const output=path.resolve(root,options['output-dir']||`dist/release-${version}-build${build}-${commit.slice(0,12)}`);
  if(fs.existsSync(output))fail('Release output already exists. Choose a new directory; candidates and evidence are never replaced.');
  return {schemaVersion:1,commit,tree:git(root,['rev-parse',`${commit}^{tree}`]),version,build,
    output,artifactName,artifactURL,feedURL,publicKey,identity,notaryProfile,keyAccount};
}

export function prepareRelease({root=repository,plan,env=process.env,run=execFileSync}){
  // Reserve before exporting so concurrent invocations cannot replace evidence.
  fs.mkdirSync(path.dirname(plan.output),{recursive:true});
  fs.mkdirSync(plan.output);
  const source=path.join(plan.output,'source');
  fs.mkdirSync(source);
  const archive=path.join(plan.output,'source.tar');
  const archiveFD=fs.openSync(archive,'wx');
  try{run('git',['archive','--format=tar',plan.commit],{cwd:root,stdio:['ignore',archiveFD,'inherit']});}
  finally{fs.closeSync(archiveFD);}
  run('tar',['-xf',archive,'-C',source],{stdio:'inherit'});
  const candidate=path.join(plan.output,'candidate');
  const app=path.join(candidate,'Agent Deck.app');
  const notary=path.join(plan.output,'notary');
  const release=path.join(plan.output,'release');
  const childEnv={...env,AGENT_DECK_UPDATE_FEED:plan.feedURL,AGENT_DECK_UPDATE_PUBLIC_KEY:plan.publicKey,
    AGENT_DECK_SIGN_IDENTITY:plan.identity,AGENT_DECK_NOTARY_PROFILE:plan.notaryProfile};
  const steps=[];
  const executeCommand=(step,command,args)=>{
    run(command,args,{cwd:source,env:childEnv,stdio:'inherit'});
    steps.push({step,completedAt:new Date().toISOString()});
  };
  const execute=(script,args=[])=>executeCommand(script,process.execPath,[path.join(source,'scripts',script),...args]);
  const startedAt=new Date().toISOString();
  const input={schemaVersion:1,source:{commit:plan.commit,tree:plan.tree,clean:true,archiveSha256:hash(archive)},
    version:plan.version,build:plan.build,update:{feedURL:plan.feedURL,publicKey:plan.publicKey,artifactURL:plan.artifactURL},startedAt};
  fs.writeFileSync(path.join(plan.output,'release-inputs.json'),JSON.stringify(input,null,2)+'\n',{flag:'wx'});
  try{
    const daemonTests=fs.readdirSync(path.join(source,'daemon')).filter(name=>name.endsWith('.test.mjs')).sort().map(name=>path.join(source,'daemon',name));
    if(!daemonTests.length)fail('No daemon tests found in the committed source snapshot.');
    executeCommand('daemon tests',process.execPath,['--test',...daemonTests]);
    execute('test-browser-bridge.mjs');
    execute('test-benchmark-native.mjs');
    execute('release-native.test.mjs');
    for(const script of ['test-subscription-planner.py','test-subscription-task.py','test-robin-dashboard-qa.py','test-private-updates.py'])executeCommand(script,'python3',[path.join(source,'scripts',script)]);
    executeCommand('Swift tests','swift',['test','--package-path',path.join(source,'native')]);
    for(const script of ['test-native.mjs','test-native-lifecycle.mjs','test-supervisor.mjs'])execute(script);
    for(const script of ['test-jarvis-native-bridge.py','test-kokoro-voice.py'])executeCommand(script,'python3',[path.join(source,'scripts',script)]);
    execute('build-native.mjs',['--universal','--release','--output-dir',candidate]);
    execute('verify-native-release.mjs',['--app',app]);
    execute('notarize-native.mjs',['--app',app,'--output-dir',notary]);
    execute('package-preview.mjs',['--app',app,'--output-dir',release]);
    execute('prepare-update-feed.mjs',['--app',app,'--output-dir',release,'--artifact-url',plan.artifactURL,'--key-account',plan.keyAccount]);
    const files=[plan.artifactName,plan.artifactName+'.sha256','appcast.xml'];
    const notarization=JSON.parse(fs.readFileSync(path.join(notary,'notarization.json'),'utf8'));
    if(notarization.status!=='Accepted')fail('Notarization evidence must report Accepted before preparing provenance.');
    const provenance={...input,completedAt:new Date().toISOString(),steps,notarization,
      artifacts:files.map(name=>({name,sha256:hash(path.join(release,name)),bytes:fs.statSync(path.join(release,name)).size})),
      installed:false,published:false};
    const provenancePath=path.join(release,'build-provenance.json');
    fs.writeFileSync(provenancePath,JSON.stringify(provenance,null,2)+'\n',{flag:'wx'});
    const signer=path.join(source,'native/.build/universal/artifacts/sparkle/Sparkle/bin/sign_update');
    const digest=hash(provenancePath);
    const signature=String(run(signer,['--account',plan.keyAccount,'-p',provenancePath],{cwd:source,encoding:'utf8',stdio:['ignore','pipe','inherit']})).trim();
    if(!/^[A-Za-z0-9+/]{86}==$/.test(signature)||Buffer.from(signature,'base64').length!==64)fail('Provenance signer did not return a valid Ed25519 signature.');
    if(hash(provenancePath)!==digest)fail('Provenance changed during signing; preserve the output and investigate.');
    run(signer,['--account',plan.keyAccount,'--verify',provenancePath,signature],{cwd:source,stdio:'inherit'});
    fs.writeFileSync(provenancePath+'.ed25519',signature+'\n',{flag:'wx'});
    fs.writeFileSync(provenancePath+'.sha256',`${hash(provenancePath)}  build-provenance.json\n`,{flag:'wx'});
    return {app,release,provenancePath};
  }catch(error){
    fs.writeFileSync(path.join(plan.output,'release-failure.json'),JSON.stringify({commit:plan.commit,failedAt:new Date().toISOString(),completedSteps:steps,nextStep:'Preserve this directory for inspection; start a new directory after resolving the failed gate.'},null,2)+'\n',{flag:'wx'});
    throw error;
  }
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{
    const options=parseOptions(process.argv.slice(2));
    const plan=createPlan({options});
    if(options.plan)console.log(JSON.stringify({...plan,identity:'configured locally',notaryProfile:'configured locally',mode:'plan only; no build, upload, install, or publication'},null,2));
    else{
      if(process.platform!=='darwin')fail('Signed native releases require macOS with Xcode and local Keychain credentials.');
      const result=prepareRelease({plan});
      console.log(`Prepared clean-commit release: ${result.release}\nProvenance: ${result.provenancePath}\nNot installed or published.`);
    }
  }catch(error){console.error(`Release preparation stopped: ${error.message}`);process.exitCode=1;}
}
