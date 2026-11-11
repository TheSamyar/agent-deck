#!/usr/bin/env node
// Owned synthetic views only. Never captures the desktop or real agent sessions.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..');
const executable=path.join(root,'native/.build/debug/AgentDeck');
if(!fs.existsSync(executable))throw Error('Run swift build --package-path native first.');
const output=path.join(root,'dist/showcase');fs.mkdirSync(output,{recursive:true});
const scenes=[['01-agents',null],['02-attention','--attention-page'],['03-actions','--actions-page'],['04-media','--media-page'],['05-tools','--tools-page']];
for(const [name,flag] of scenes)execFileSync(executable,['--render-masterhub-preview',path.join(output,name+'.png'),'--dark',...(flag?[flag]:[])],{stdio:'inherit'});
if(!process.argv.includes('--stills-only')){
  execFileSync('ffmpeg',['-version'],{stdio:'ignore'});
  const frames=scenes.map(([name])=>`file '${name}.png'\nduration 6`).join('\n')+"\nfile '05-tools.png'\n";
  fs.writeFileSync(path.join(output,'frames.txt'),frames);
  execFileSync('ffmpeg',['-y','-v','error','-f','concat','-safe','0','-i',path.join(output,'frames.txt'),'-vf','tpad=stop_mode=clone:stop_duration=1','-t','30','-r','30','-c:v','libx264','-pix_fmt','yuv420p','-an','-metadata','title=Agent Deck synthetic UI walkthrough',path.join(output,'AgentDeck-preview-walkthrough.mp4')],{stdio:'inherit'});
}
console.log('Synthetic showcase assets prepared:',output);
