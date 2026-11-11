#!/usr/bin/env node
/**
 * Install or remove AI Agent Deck hooks, the launch agent, and the keypad profile.
 * Never replaces a config file it cannot parse.
 *
 *   node scripts/install.mjs
 *   node scripts/install.mjs --uninstall
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HOME = os.homedir();
const HOOK_SCRIPT = path.join(ROOT, 'bin', 'agent-hook.mjs');
const DAEMON_SCRIPT = path.join(ROOT, 'daemon', 'server.mjs');
const PLUGIN_DIST = path.join(ROOT, 'plugin', 'dist');
const LABEL = 'com.ai-agent-deck.daemon';
const OLD_LABEL = 'com.samyar.ai-agent-deck';
const HOOK_MARK = 'agent-hook.mjs';
const PAGE_12 = 'A1A6E47DEC404F99832ABB851D17F749';
const PAGE_9 = 'A1A6E47DEC724F99832ABB851D17F772';
const ACTION_PREFIX = '$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___';
const DIAL_ACTION = '$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentDialAdjustment';
const DIAL_RESET = '$Reset___AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentDialAdjustment';

let cachedNode = '';

function nodeBin() {
  if (!cachedNode) cachedNode = execSync('command -v node', { encoding: 'utf8' }).trim();
  if (!cachedNode) throw new Error('node is not on PATH');
  return cachedNode;
}

function cmdFor(agent, event) {
  return `"${nodeBin()}" "${HOOK_SCRIPT}" ${agent} ${event}`;
}

function domain() {
  return `gui/${process.getuid()}`;
}

function backupFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  const bak = `${filePath}.pre-agent-deck.bak`;
  if (!fs.existsSync(bak)) fs.copyFileSync(filePath, bak);
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) return { ok: true, missing: true, data: null };
  try {
    return { ok: true, missing: false, data: JSON.parse(fs.readFileSync(filePath, 'utf8')) };
  } catch (err) {
    console.error(`[!] Not changing ${filePath}: the file is not valid JSON (${err.message}).`);
    return { ok: false, missing: false, data: null };
  }
}

function asObject(read, filePath) {
  if (!read.ok) return null;
  if (read.missing) return {};
  if (!read.data || typeof read.data !== 'object' || Array.isArray(read.data)) {
    console.error(`[!] Not changing ${filePath}: expected a JSON object.`);
    return null;
  }
  return read.data;
}

function withoutOurs(list) {
  return (Array.isArray(list) ? list : []).filter((entry) => {
    const text = JSON.stringify(entry);
    return !text.includes(HOOK_MARK) && !text.includes('codex-notify.sh');
  });
}

function setHook(hooks, name, entries, remove) {
  const kept = withoutOurs(hooks[name]);
  if (remove) {
    if (kept.length) hooks[name] = kept;
    else delete hooks[name];
    return;
  }
  hooks[name] = kept.concat(entries);
}

function escapeToml(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

export function hookNotifyLine(node, hookScript) {
  const argv = [node, hookScript, 'codex', 'turn-ended'];
  return `notify = [${argv.map((part) => `"${escapeToml(part)}"`).join(', ')}]`;
}

export function updateCodexNotify(toml, node, hookScript) {
  const line = hookNotifyLine(node, hookScript);
  const re = /^notify\s*=\s*(.+)$/m;
  const match = toml.match(re);
  if (!match) return { toml: `${line}\n${toml}`, changed: true, reason: 'added' };
  const value = match[1].trim();
  const previous = /(--previous-notify"\s*,\s*")((?:\\.|[^"\\])*)(")/;
  if (value.includes('--previous-notify')) {
    if (!previous.test(value)) return { toml, changed: false, reason: 'previous-notify-unparsed' };
    const escaped = escapeToml(JSON.stringify([node, hookScript, 'codex', 'turn-ended']));
    const replaced = value.replace(previous, (_, open, _old, close) => `${open}${escaped}${close}`);
    return { toml: toml.replace(re, `notify = ${replaced}`), changed: true, reason: 'previous-notify' };
  }
  if (value.includes(HOOK_MARK) || value.includes('codex-notify.sh') || value.includes('ai-agent-deck')) {
    return { toml: toml.replace(re, line), changed: true, reason: 'replaced' };
  }
  return { toml, changed: false, reason: 'left-alone' };
}

export function removeCodexNotify(toml) {
  const re = /^notify\s*=\s*(.+)$/m;
  const match = toml.match(re);
  if (!match) return { toml, changed: false };
  const value = match[1].trim();
  const ours = value.includes(HOOK_MARK) || value.includes('codex-notify.sh') || value.includes('ai-agent-deck');
  if (!ours) return { toml, changed: false };
  if (value.includes('--previous-notify')) {
    const stripped = value.replace(/,\s*"--previous-notify"\s*,\s*"(?:\\.|[^"\\])*"/, '');
    if (stripped === value) return { toml, changed: false };
    return { toml: toml.replace(re, `notify = ${stripped}`), changed: true };
  }
  const next = toml.replace(re, '').replace(/\n{3,}/g, '\n\n');
  return { toml: next, changed: true };
}

function setupAntigravity(remove) {
  const file = path.join(HOME, '.gemini', 'config', 'hooks.json');
  const read = readJson(file);
  const data = asObject(read, file);
  if (!data) return;
  if (remove) {
    if (read.missing || !Object.prototype.hasOwnProperty.call(data, 'ai-agent-deck')) return;
    delete data['ai-agent-deck'];
  } else {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    data['ai-agent-deck'] = {
      enabled: true,
      SessionStart: [{ type: 'command', command: cmdFor('antigravity', 'SessionStart'), timeout: 5 }],
      PreInvocation: [{ type: 'command', command: cmdFor('antigravity', 'PreInvocation'), timeout: 5 }],
      PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: cmdFor('antigravity', 'PreToolUse'), timeout: 5 }] }],
      PostToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: cmdFor('antigravity', 'PostToolUse'), timeout: 5 }] }],
      Stop: [{ type: 'command', command: cmdFor('antigravity', 'Stop'), timeout: 5 }],
    };
  }
  backupFile(file);
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
  console.log(`[✓] ${remove ? 'Removed' : 'Configured'} Antigravity hooks: ${file}`);
}

function setupClaude(remove) {
  const file = path.join(HOME, '.claude', 'settings.json');
  const read = readJson(file);
  if (read.missing) return;
  const data = asObject(read, file);
  if (!data) return;
  if (!data.hooks || typeof data.hooks !== 'object' || Array.isArray(data.hooks)) data.hooks = {};
  const events = [
    { name: 'SessionStart', matcher: false },
    { name: 'UserPromptSubmit', matcher: false },
    { name: 'PreToolUse', matcher: true },
    { name: 'PostToolUse', matcher: true },
    { name: 'PermissionRequest', matcher: true },
    { name: 'Notification', matcher: false },
    { name: 'Stop', matcher: false },
    { name: 'SessionEnd', matcher: false },
  ];
  for (const event of events) {
    const handler = { type: 'command', command: cmdFor('claude', event.name), timeout: 5 };
    const entry = event.matcher ? { matcher: '.*', hooks: [handler] } : { hooks: [handler] };
    setHook(data.hooks, event.name, [entry], remove);
  }
  backupFile(file);
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
  console.log(`[✓] ${remove ? 'Removed' : 'Configured'} Claude Code hooks: ${file}`);
}

function setupCursor(remove) {
  const file = path.join(HOME, '.cursor', 'hooks.json');
  const read = readJson(file);
  const data = asObject(read, file);
  if (!data) return;
  if (!data.hooks || typeof data.hooks !== 'object' || Array.isArray(data.hooks)) data.hooks = {};
  if (!data.version) data.version = 1;
  for (const name of ['beforeSubmitPrompt', 'afterMCPExecution', 'afterShellExecution', 'afterFileEdit', 'stop']) {
    setHook(data.hooks, name, [{ command: cmdFor('cursor', name) }], remove);
  }
  if (!remove) fs.mkdirSync(path.dirname(file), { recursive: true });
  if (remove && read.missing) return;
  backupFile(file);
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
  console.log(`[✓] ${remove ? 'Removed' : 'Configured'} Cursor hooks: ${file}`);
}

function setupGemini(remove) {
  const file = path.join(HOME, '.gemini', 'settings.json');
  const read = readJson(file);
  const data = asObject(read, file);
  if (!data) return;
  if (!data.hooks || typeof data.hooks !== 'object' || Array.isArray(data.hooks)) data.hooks = {};
  const events = [
    { name: 'SessionStart', matcher: false },
    { name: 'BeforeAgent', matcher: false },
    { name: 'BeforeTool', matcher: true },
    { name: 'AfterTool', matcher: true },
    { name: 'Notification', matcher: false },
    { name: 'AfterAgent', matcher: false },
  ];
  for (const event of events) {
    const handler = { type: 'command', command: cmdFor('gemini', event.name), timeout: 5 };
    const entry = event.matcher ? { matcher: '.*', hooks: [handler] } : { hooks: [handler] };
    setHook(data.hooks, event.name, [entry], remove);
  }
  if (!remove) fs.mkdirSync(path.dirname(file), { recursive: true });
  if (remove && read.missing) return;
  backupFile(file);
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
  console.log(`[✓] ${remove ? 'Removed' : 'Configured'} Gemini CLI hooks: ${file}`);
}

function setupCodex(remove) {
  const configFile = path.join(HOME, '.codex', 'config.toml');
  if (fs.existsSync(configFile)) {
    const toml = fs.readFileSync(configFile, 'utf8');
    const result = remove
      ? removeCodexNotify(toml)
      : updateCodexNotify(toml, nodeBin(), HOOK_SCRIPT);
    if (!result.changed && result.reason === 'left-alone') {
      console.error('[!] Codex notify belongs to another tool. Left it unchanged.');
    } else if (!result.changed && result.reason === 'previous-notify-unparsed') {
      console.error('[!] Codex notify has --previous-notify in a shape this installer does not recognize. Left it unchanged.');
    } else if (result.changed) {
      backupFile(configFile);
      fs.writeFileSync(configFile, result.toml);
      console.log(`[✓] ${remove ? 'Removed' : 'Configured'} Codex notify: ${configFile}`);
    }
  }

  const hooksFile = path.join(HOME, '.codex', 'hooks.json');
  const read = readJson(hooksFile);
  const data = asObject(read, hooksFile);
  if (!data) return;
  if (!data.hooks || typeof data.hooks !== 'object' || Array.isArray(data.hooks)) data.hooks = {};
  for (const name of ['SessionStart', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop']) {
    const entry = {
      matcher: '.*',
      hooks: [{ type: 'command', command: cmdFor('codex', name), timeout: 5 }],
    };
    setHook(data.hooks, name, [entry], remove);
  }
  if (!remove) fs.mkdirSync(path.dirname(hooksFile), { recursive: true });
  if (remove && read.missing) return;
  backupFile(hooksFile);
  fs.writeFileSync(hooksFile, JSON.stringify(data, null, 2) + '\n');
  console.log(`[✓] ${remove ? 'Removed' : 'Configured'} Codex hooks: ${hooksFile}`);
}

function pluginDirs() {
  return [
    path.join(HOME, '.local', 'share', 'Loupedeck', 'Plugins', 'AiAgentDeck'),
    path.join(HOME, 'Library', 'Application Support', 'Logi', 'LogiPluginService', 'Plugins', 'AiAgentDeck'),
  ];
}

function installPlugin() {
  if (!fs.existsSync(path.join(PLUGIN_DIST, 'AiAgentDeckPlugin.dll'))) {
    console.error('[!] Plugin is not built. Run: node scripts/build-and-deploy.mjs');
    return;
  }
  for (const target of pluginDirs()) {
    fs.rmSync(target, { recursive: true, force: true });
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.cpSync(PLUGIN_DIST, target, { recursive: true });
    console.log('[✓] Installed plugin:', target);
  }
}

function removePlugin() {
  for (const target of pluginDirs()) {
    fs.rmSync(target, { recursive: true, force: true });
    console.log('[✓] Removed plugin:', target);
  }
}

const BUTTONS_12 = ['antigravity', 'claude', 'cursor', 'gemini', 'codex', 'summary', 'approve', 'deny', 'dashboard', null, null, null];
const BUTTONS_9 = ['antigravity', 'claude', 'cursor', 'gemini', 'codex', 'summary', 'approve', 'deny', 'dashboard'];

function ourPage(page) {
  return page && (page.name === PAGE_12 || page.name === PAGE_9 || page.displayName === 'AI Agents');
}

function injectProfile(file, remove) {
  const read = readJson(file);
  const prof = asObject(read, file);
  if (!prof || read.missing) return;

  if (!Array.isArray(prof.additionalNativePluginNames)) prof.additionalNativePluginNames = [];
  prof.additionalNativePluginNames = prof.additionalNativePluginNames.filter((name) => name !== 'AiAgentDeck');
  if (!remove) prof.additionalNativePluginNames.push('AiAgentDeck');

  const modes = prof?.layout?.layoutModes;
  if (Array.isArray(modes)) {
    for (const mode of modes) {
      if (Array.isArray(mode.touchPages)) {
        mode.touchPages = mode.touchPages.filter((page) => !ourPage(page));
        if (!remove) {
          mode.touchPages.unshift({
            $type: 'Loupedeck.Service.ProfileLayoutButtonPage, LoupedeckService',
            name: PAGE_12,
            displayName: 'AI Agents',
            description: 'Live status for Antigravity, Claude, Cursor, Gemini, and Codex',
            controls: BUTTONS_12.map((key) => ({
              $type: 'Loupedeck.Service.ProfileLayoutButton, LoupedeckService',
              pressAction: key ? `${ACTION_PREFIX}${key}` : null,
              fnPressAction: null,
            })),
            dynamicPageName: null,
            dynamicPagePluginName: null,
            dynamicPageNumber: 0,
          });
        }
      }
      if (Array.isArray(mode.workspaces)) {
        for (const workspace of mode.workspaces) {
          if (Array.isArray(workspace.pressPages)) {
            workspace.pressPages = workspace.pressPages.filter((page) => !ourPage(page));
            if (!remove) {
              workspace.pressPages.unshift({
                $type: 'Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutPage7, LoupedeckService',
                name: PAGE_9,
                displayName: 'AI Agents',
                description: 'Live status for Antigravity, Claude, Cursor, Gemini, and Codex',
                controls: BUTTONS_9.map((key, index) => ({
                  $type: 'Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutControl7, LoupedeckService',
                  controlId: index,
                  pressAction: `${ACTION_PREFIX}${key}`,
                  rotateAction: null,
                })),
                dynamicPageName: null,
                dynamicPagePluginName: null,
                dynamicPageNumber: 0,
              });
            }
          }
          if (Array.isArray(workspace.touchPageNames)) {
            workspace.touchPageNames = workspace.touchPageNames.filter((id) => id !== PAGE_12);
            if (!remove) workspace.touchPageNames.unshift(PAGE_12);
          }
        }
      }
      if (Array.isArray(mode.touchPages) && Array.isArray(mode.encoderPages) && mode.encoderPages[0]?.controls?.[0]) {
        const dial = mode.encoderPages[0].controls[0];
        if (remove) {
          if (String(dial.rotateAction || '').includes('AiAgentDialAdjustment')) dial.rotateAction = null;
          if (String(dial.pressAction || '').includes('AiAgentDialAdjustment')) dial.pressAction = null;
        } else {
          dial.rotateAction = DIAL_ACTION;
          dial.pressAction = DIAL_RESET;
        }
      }
    }
  }

  const hasTouchPage = Array.isArray(modes) && modes.some((mode) => Array.isArray(mode.touchPages));
  const round = prof.layout?.roundPage?.controls;
  if (hasTouchPage && Array.isArray(round) && round[0]) {
    if (remove) {
      if (String(round[0].pressAction || '').includes(PAGE_12)) round[0].pressAction = null;
    } else {
      const system = modes.find((mode) => mode.modeName === 'System') || modes[0];
      const workspace = system?.workspaces?.[0];
      if (workspace?.name) {
        round[0].pressAction = `$@Generic___@ChangeTouchPage___System|${workspace.name}|${PAGE_12}`;
      }
    }
  }

  backupFile(file);
  fs.writeFileSync(file, JSON.stringify(prof, null, 2));
  console.log(`[✓] ${remove ? 'Removed AI Agents page from' : 'Updated'} ${file}`);
}

function visitProfiles(remove) {
  const roots = [
    path.join(HOME, '.local', 'share', 'Loupedeck'),
    path.join(HOME, 'Library', 'Application Support', 'Logi', 'LogiPluginService'),
  ];
  for (const root of roots) {
    const apps = path.join(root, 'Applications');
    if (!fs.existsSync(apps)) continue;
    for (const device of fs.readdirSync(apps)) {
      const profiles = path.join(apps, device, '@_defaultmac', 'Profiles');
      if (!fs.existsSync(profiles)) continue;
      for (const id of fs.readdirSync(profiles)) {
        const file = path.join(profiles, id, 'ProfileInfo.json');
        if (fs.existsSync(file)) injectProfile(file, remove);
      }
    }
  }
}

function plistPath(label) {
  return path.join(HOME, 'Library', 'LaunchAgents', `${label}.plist`);
}

function bootout(file) {
  try { execSync(`launchctl bootout ${domain()} "${file}"`, { stdio: 'ignore' }); } catch {}
  try { execSync(`launchctl unload "${file}"`, { stdio: 'ignore' }); } catch {}
}

function installLaunchAgent() {
  const file = plistPath(LABEL);
  const old = plistPath(OLD_LABEL);
  const logFile = path.join(HOME, 'Library', 'Logs', 'ai-agent-deck.log');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.mkdirSync(path.dirname(logFile), { recursive: true });
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${nodeBin()}</string>
    <string>${DAEMON_SCRIPT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>WorkingDirectory</key>
  <string>${ROOT}</string>
  <key>StandardOutPath</key>
  <string>${logFile}</string>
  <key>StandardErrorPath</key>
  <string>${logFile}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>AGENT_DECK_PORT</key>
    <string>19420</string>
  </dict>
</dict>
</plist>
`;
  // Preserve live sessions when upgrading an older daemon that did not save them.
  try {
    const snapshot = JSON.parse(execSync('curl -fsS --max-time 2 http://127.0.0.1:19420/status', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
    const cache = path.join(HOME, 'Library', 'Caches', 'ai-agent-deck');
    fs.mkdirSync(cache, { recursive: true });
    fs.writeFileSync(path.join(cache, 'sessions.json'), JSON.stringify({sessions: snapshot.sessions, selectedSessionId: snapshot.selectedSessionId}), { mode: 0o600 });
  } catch {}
  bootout(old);
  bootout(file);
  fs.rmSync(old, { force: true });
  fs.writeFileSync(file, plist);
  try {
    execSync(`launchctl bootstrap ${domain()} "${file}"`);
  } catch {
    execSync(`launchctl load -w "${file}"`);
  }
  console.log('[✓] Launch agent loaded:', file);
}

function removeLaunchAgent() {
  for (const label of [LABEL, OLD_LABEL]) {
    const file = plistPath(label);
    bootout(file);
    fs.rmSync(file, { force: true });
  }
  console.log('[✓] Launch agent removed');
}

function restartLogi() {
  try { execSync('killall LogiPluginService 2>/dev/null || true'); } catch {}
  execSync('sleep 1');
  try {
    execSync('open -g "/Applications/Utilities/LogiPluginService.app"');
    console.log('[✓] Restarted LogiPluginService');
  } catch (err) {
    console.error('[!] Could not start LogiPluginService:', err.message);
  }
}

function compileHelper() {
  const nodeReal = fs.realpathSync(execSync('command -v node', { encoding: 'utf8' }).trim());
  const include = path.resolve(path.dirname(nodeReal), '../include/node');
  execSync([
    'clang -fobjc-arc -dynamiclib',
    `-o ${JSON.stringify(path.join(ROOT, 'daemon/osa.node'))}`,
    JSON.stringify(path.join(ROOT, 'daemon/osa.m')),
    `-I ${JSON.stringify(include)}`,
    '-framework Foundation -framework OSAKit -framework Carbon',
    '-undefined dynamic_lookup',
  ].join(' '), { stdio: 'inherit' });
  console.log('[✓] Built the AppleScript helper');
}

function install() {
  console.log(`Installing AI Agent Deck from ${ROOT}`);
  compileHelper();
  setupAntigravity(false);
  setupClaude(false);
  setupCursor(false);
  setupGemini(false);
  setupCodex(false);
  installPlugin();
  visitProfiles(false);
  installLaunchAgent();
  restartLogi();
  console.log('\nAI Agent Deck is installed. Dashboard: http://127.0.0.1:19420');
}

function uninstall() {
  console.log(`Removing AI Agent Deck hooks that point at ${ROOT}`);
  setupAntigravity(true);
  setupClaude(true);
  setupCursor(true);
  setupGemini(true);
  setupCodex(true);
  visitProfiles(true);
  removePlugin();
  removeLaunchAgent();
  restartLogi();
  console.log('\nAI Agent Deck is uninstalled. Config backups end in .pre-agent-deck.bak');
}

if (import.meta.main) {
  if (process.argv.includes('--runtime-only')) { compileHelper(); installLaunchAgent(); }
  else if (process.argv.includes('--uninstall')) uninstall();
  else install();
}
