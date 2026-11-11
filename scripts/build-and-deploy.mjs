#!/usr/bin/env node
import { execFileSync, execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HOME = os.homedir();
const DIST = path.join(ROOT, 'plugin', 'dist');
const TARGETS = [
  path.join(HOME, '.local', 'share', 'Loupedeck', 'Plugins', 'AiAgentDeck'),
  path.join(HOME, 'Library', 'Application Support', 'Logi', 'LogiPluginService', 'Plugins', 'AiAgentDeck'),
];

function bin(name) {
  const found = execSync(`command -v ${name}`, { encoding: 'utf8' }).trim();
  if (!found) throw new Error(`Could not find ${name} on PATH`);
  return found;
}

function findDll(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      const found = findDll(full);
      if (found) return found;
    } else if (entry.name === 'AiAgentDeckPlugin.dll') return full;
  }
  return '';
}

const dotnet = bin('dotnet');
console.log('1. Building plugin...');
execFileSync(dotnet, ['build', '-c', 'Release', path.join(ROOT, 'plugin', 'AiAgentDeckPlugin.csproj')], { stdio: 'inherit' });

const dll = findDll(path.join(ROOT, 'plugin', 'bin', 'Release'));
if (!dll) throw new Error('Build finished without AiAgentDeckPlugin.dll');
const builtDir = path.dirname(dll);

console.log('2. Assembling dist...');
fs.rmSync(DIST, { recursive: true, force: true });
fs.mkdirSync(DIST, { recursive: true });
for (const name of ['AiAgentDeckPlugin.dll', 'AiAgentDeckPlugin.pdb', 'AiAgentDeckPlugin.deps.json']) {
  const source = path.join(builtDir, name);
  if (fs.existsSync(source)) fs.copyFileSync(source, path.join(DIST, name));
}
fs.cpSync(path.join(ROOT, 'plugin', 'metadata'), path.join(DIST, 'metadata'), { recursive: true });

console.log('3. Writing PackageHash.bin...');
execFileSync(dotnet, ['run', '--project', path.join(ROOT, 'scripts', 'RehashRunner.csproj'), '--', DIST], { stdio: 'inherit' });

console.log('4. Installing into Loupedeck and LogiPluginService...');
for (const target of TARGETS) {
  fs.rmSync(target, { recursive: true, force: true });
  fs.cpSync(DIST, target, { recursive: true });
  console.log('   ', target);
}

const packed = path.join(ROOT, 'plugin', 'AiAgentDeck.lplug4');
fs.rmSync(packed, { force: true });
execFileSync('/usr/bin/zip', ['-r', '-X', packed, '.'], { cwd: DIST, stdio: 'inherit' });
console.log('   ', packed);

console.log('5. Restarting LogiPluginService...');
try { execSync('killall LogiPluginService 2>/dev/null || true'); } catch {}
execSync('sleep 1.5');
execSync('open -g "/Applications/Utilities/LogiPluginService.app"');
console.log('Plugin deployed.');
