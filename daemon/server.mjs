#!/usr/bin/env node
/**
 * AI Agent Deck daemon. Sessions, keypad layout, and tile art live here.
 * The Loupedeck plugin only draws the SVG and forwards each press once.
 */

import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { createRequire } from 'node:module';
import {
  agentMeta,
  applyTimeouts,
  approveKey,
  cursorWorkspace,
  buildTiles,
  classifyEvent,
  cycleIds,
  isLocalHost,
  nextSelection,
  pressGuard,
  readHook,
  resolveApproval,
  resolveStop,
  safeBundleId,
  sessionId,
  slug,
  pidAlive,
} from './logic.mjs';
import { renderTile } from './tiles.mjs';
import { dashboardHtml } from './dashboard.mjs';
import { CURSOR_BUNDLE, hostFor, matchWorkspace, layoutSignature, serialQueue, windowMenuScript, focusCursorScript, terminalScript, focusWindowScript } from './actions.mjs';

export {
  classifyEvent,
  readHook,
  slug,
  sessionId,
  resolveApproval,
  resolveStop,
  buildTiles,
  pressGuard,
  isLocalHost,
  pidAlive,
  applyTimeouts,
  cursorWorkspace,
};
export { renderTile } from './tiles.mjs';
export { xmlEscape, fitLabel } from './tiles.mjs';

const PORT = Number(process.env.AGENT_DECK_PORT || 19420);
const HEADER = 'x-agent-deck';
const STATE_FILE = path.join(os.homedir(), 'Library', 'Caches', 'ai-agent-deck', 'sessions.json');

const sessions = new Map();
const recentEvents = [];
let forceMulti = false;
let selectedSessionId = '';
let layoutChangedAt = 0;
let lastLayout = '';
let lastPress = { key: '', at: 0 };
let lastError = '';
let lastErrorAt = 0;
let scanning = false;
let revision = 0;
let tileSignature = '';
let lastAction = null;
const enqueueAction = serialQueue();

const CURSOR_WINDOWS = windowMenuScript();

function noteError(message) {
  const text = String(message || '').replace(/\s+/g, ' ').trim().slice(0, 240);
  if (!text) return;
  const changed = text !== lastError;
  lastError = text;
  lastErrorAt = Date.now();
  if (changed) console.error(`[ai-agent-deck] ${text}`);
}

function logEvent(session, eventName) {
  recentEvents.unshift({
    ts: Date.now(),
    time: new Date().toLocaleTimeString(),
    sessionId: session?.id || '',
    agentId: session?.agentId || '',
    eventName: eventName || '',
    status: session?.status || '',
    detail: session?.detail || '',
    workspace: session?.workspace || '',
  });
  if (recentEvents.length > 60) recentEvents.length = 60;
}

function blankSession(agentId, workspace) {
  const meta = agentMeta(agentId);
  const name = String(workspace || 'main');
  return {
    id: sessionId(agentId, name),
    agentId: String(agentId || 'agent').toLowerCase(),
    agentName: meta.name,
    shortName: meta.shortName,
    instanceLabel: name,
    accentColor: meta.color,
    status: 'IDLE',
    detail: 'Ready',
    tool: '',
    workspace: name,
    cwd: '',
    bundleId: '',
    pid: 0,
    updatedAt: Date.now(),
    lastHookAt: 0,
    eventCount: 0,
  };
}

export function applyHook(agentId, eventName, body) {
  const info = readHook(body);
  const inner = body && body.data && typeof body.data === 'object' ? body.data : (body || {});
  const classified = classifyEvent(eventName, inner);
  const id = sessionId(agentId, info.workspace);

  if (classified.remove) {
    if (sessions.has(id)) {
      sessions.delete(id);
    } else {
      const mine = [...sessions.values()].filter((session) => session.agentId === String(agentId).toLowerCase());
      if (mine.length === 1) sessions.delete(mine[0].id);
    }
    return { removed: id };
  }

  let session = sessions.get(id);
  if (!session) {
    session = blankSession(agentId, info.workspace);
    sessions.set(id, session);
  }
  if (info.pid) session.pid = info.pid;
  if (info.bundleId) session.bundleId = info.bundleId;
  if (info.cwd) session.cwd = info.cwd;
  for (const field of ['tty', 'terminalId', 'agentSessionId']) if (info[field]) session[field] = info[field];
  session.workspace = info.workspace;
  session.instanceLabel = info.workspace;
  session.updatedAt = Date.now();
  session.lastHookAt = Date.now();
  session.eventCount += 1;
  if (!classified.ignore) {
    session.status = classified.status;
    session.detail = String(classified.detail || '').slice(0, 48);
    if (info.tool) session.tool = info.tool;
  }
  logEvent(session, eventName);
  return session;
}

const require = createRequire(import.meta.url);
let osaAddon;

function appleScript(args) {
  return new Promise((resolve) => {
    try {
      osaAddon ??= require('./osa.node');
    } catch (err) {
      resolve({ ok: false, stdout: '', error: 'AppleScript helper is missing. Run node scripts/install.mjs' });
      return;
    }
    const scripts = [];
    const argv = [];
    let afterDash = false;
    for (let i = 0; i < args.length; i++) {
      if (!afterDash && args[i] === '--') { afterDash = true; continue; }
      if (!afterDash && args[i] === '-e') { scripts.push(args[++i] ?? ''); continue; }
      if (afterDash) argv.push(String(args[i]));
    }
    try {
      const result = osaAddon.run(scripts.join('\n'), argv);
      resolve({ ok: !!result.ok, stdout: String(result.stdout || ''), error: String(result.error || '') });
    } catch (err) {
      resolve({ ok: false, stdout: '', error: err.message });
    }
  });
}

function run(cmd, args, timeout = 4000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout }, (err, stdout, stderr) => {
      resolve({
        ok: !err,
        stdout: String(stdout || ''),
        error: err ? String(stderr || err.message).trim() : '',
      });
    });
  });
}

function appRunning(pattern) {
  return run('/usr/bin/pgrep', ['-f', pattern], 2000).then((result) => result.ok && result.stdout.trim().length > 0);
}

function cleanTitle(title) {
  return cursorWorkspace(title);
}

async function cursorWindows() {
  const result = await appleScript(['-e', CURSOR_WINDOWS]);
  if (!result.ok) {
    const denied = result.error.includes('assistive access') || result.error.includes('-1719');
    noteError(denied
      ? 'Cursor windows are hidden. Turn on node in System Settings → Privacy & Security → Accessibility.'
      : `Could not read Cursor windows. ${result.error}`);
    return null;
  }
  if (lastError.startsWith('Cursor windows are hidden') || lastError.startsWith('Could not read Cursor windows')) lastError = '';
  if (!result.stdout.trim()) return [];
  return result.stdout.split('\n').map((part) => cleanTitle(part)).filter(Boolean);
}

async function scan() {
  if (scanning) return;
  scanning = true;
  try {
    applyTimeouts(sessions, Date.now());
    const [cursorUp, agyUp] = await Promise.all([
      appRunning('/Applications/Cursor\\.app'),
      appRunning('Antigravity\\.app'),
    ]);
    const windows = cursorUp ? await cursorWindows() : [];

    for (const [id, session] of [...sessions]) {
      if (session.agentId === 'cursor') {
        if (!cursorUp) sessions.delete(id);
        else if (windows && !windows.some((title) => slug(title) === slug(session.workspace))) sessions.delete(id);
        continue;
      }
      if (session.agentId === 'antigravity') {
        if (!agyUp) sessions.delete(id);
        continue;
      }
      if (!pidAlive(session.pid)) sessions.delete(id);
    }

    if (cursorUp && windows) {
      for (const title of windows) {
        const id = sessionId('cursor', title);
        const existing = sessions.get(id);
        if (!existing) sessions.set(id, blankSession('cursor', title));
        else if (existing.workspace !== title) existing.workspace = title;
      }
    }
  } catch (err) {
    noteError(err.message);
  } finally {
    scanning = false;
  }
}

async function focusSession(session, key = '') {
  if (!session) return { ok: false, error: 'No session' };
  const bundle = hostFor(session);
  if (bundle === CURSOR_BUNDLE) {
    const menu = await appleScript(['-e', CURSOR_WINDOWS]);
    if (!menu.ok) return menu;
    let title;
    try { title = matchWorkspace(menu.stdout.split('\n').filter(Boolean), session.workspace); }
    catch (err) { return { ok: false, error: err.message }; }
    const focused = await appleScript(['-e', focusCursorScript(), '--', title]);
    if (!focused.ok || !key) return focused;
    // A workspace can contain several terminals. A window match alone cannot authorize typing.
    return { ok: false, error: `Opened ${session.workspace}. Keyboard control requires an identifiable terminal tab; Cursor does not expose this session's terminal identity.` };
  }
  if (bundle === 'com.apple.Terminal' || bundle === 'com.googlecode.iterm2') {
    if (!session.tty && !(bundle === 'com.googlecode.iterm2' && session.terminalId)) {
      return { ok: false, error: 'Terminal identity is missing. Start a new agent session to report its terminal.' };
    }
    return appleScript(['-e', terminalScript(bundle, session.tty, session.terminalId, key), '--', session.tty || '', session.terminalId || '']);
  }
  if (key) return { ok: false, error: 'Keyboard control is unavailable: this host does not expose the target terminal.' };
  if (!bundle) return { ok: false, error: `No host app is known for ${session.shortName}. Start a new agent session.` };
  const listed = await appleScript(['-e', `tell application "System Events"
    set hostProcess to first application process whose bundle identifier is "${bundle}"
    set windowNames to name of every window of hostProcess
    set AppleScript's text item delimiters to linefeed
    return windowNames as text
  end tell`]);
  if (!listed.ok) return listed;
  try {
    const title = matchWorkspace(listed.stdout.split('\n').filter(Boolean), session.workspace);
    return appleScript(['-e', focusWindowScript(bundle), '--', title]);
  } catch (err) { return { ok: false, error: err.message }; }
}


function mark(session, status, detail) {
  session.status = status;
  session.detail = detail;
  session.updatedAt = Date.now();
  logEvent(session, detail);
}

export async function execute(action, target, focus = focusSession) {
  if (action === 'toggle_mode' || action === 'mode') {
    forceMulti = !forceMulti;
    layoutChangedAt = Date.now();
    return { ok: true, action: 'toggle_mode', forceMulti };
  }
  if (action === 'dashboard') {
    const result = await run('/usr/bin/open', [`http://127.0.0.1:${PORT}`], 3000);
    if (!result.ok) noteError(`Could not open the dashboard. ${result.error}`);
    return { ok: result.ok, action: 'dashboard' };
  }
  if (action === 'approve' || action === 'deny') {
    const session = resolveApproval(sessions, target);
    if (!session) return { ok: false, error: 'Nothing is waiting for approval' };
    const key = action === 'deny' ? 'escape' : approveKey(session.agentId);
    if (!key) return { ok: false, error: `Allow is not available for ${session.agentId}` };
    const result = await focus(session, key);
    if (result.ok) mark(session, action === 'deny' ? 'IDLE' : 'WORKING', action === 'deny' ? 'Denied' : 'Approved');
    return { ...result, action, session: session.id };
  }
  if (action === 'stop') {
    const session = resolveStop(sessions, target);
    if (!session) return { ok: false, error: 'Stop is only for a terminal agent' };
    const result = await focus(session, 'interrupt');
    if (result.ok) mark(session, 'IDLE', 'Interrupted');
    return { ...result, action, session: session.id };
  }
  if (action !== 'focus') return { ok: false, error: 'Unknown action' };

  const session = sessions.get(target);
  if (!session) return { ok: false, error: 'That agent is not running' };
  selectedSessionId = session.id;
  const focused = await focus(session);
  if (focused.ok && session.status === 'DONE') mark(session, 'IDLE', 'Ready');
  return { ...focused, action: 'focus', session: session.id };
}

export function publicStatus(now = Date.now()) {
  applyTimeouts(sessions, now);
  const built = buildTiles({ sessions, selectedId: selectedSessionId, forceMulti, now });
  if (lastLayout && lastLayout !== built.layoutMode) layoutChangedAt = now;
  lastLayout = built.layoutMode;
  selectedSessionId = built.selectedSessionId;
  const signature = layoutSignature(built.tiles);
  if (signature !== tileSignature) { revision++; tileSignature = signature; }
  const frame = Math.floor(now / 400) % 4;
  return {
    ok: true,
    timestamp: now,
    revision,
    lastAction,
    layoutMode: built.layoutMode,
    selectedSessionId: built.selectedSessionId,
    sessionCount: sessions.size,
    summary: built.summary,
    sessions: Object.fromEntries(sessions),
    tiles: built.tiles.map((tile) => {
      const feedback = lastAction && lastAction.key === tile.key && now - lastAction.timestamp < 6000 && !lastAction.ok;
      return { ...tile, svg: renderTile(feedback ? { ...tile, type: 'action', label: 'FAILED', sublabel: 'SEE DECK', detail: lastAction.message, status: 'ERROR', color: '#ef4444', enabled: true } : tile, frame) };
    }),
    dial: { ...built.dial, svg: renderTile(lastAction?.key === 'dial' && !lastAction.ok && now - lastAction.timestamp < 6000 ? { ...built.dial, type: 'action', label: 'FAILED', sublabel: 'SEE DECK', detail: lastAction.message, status: 'ERROR' } : built.dial, frame) },
    lastError: now - lastErrorAt < 60000 ? lastError : '',
    recentEvents: recentEvents.slice(0, 30),
  };
}

function tileForKey(key, status) {
  if (/^\d$/.test(key)) return status.tiles[Number(key)] || null;
  return status.tiles.find((tile) => tile.key === key) || null;
}

export async function handlePress(key, expectedRevision) {
  const now = Date.now();
  const layoutBefore = lastLayout;
  const status = publicStatus(now);
  if (expectedRevision != null && Number(expectedRevision) !== status.revision) return { ok: false, ignored: 'stale', error: 'The layout changed. Press the updated key.' };
  const blocked = pressGuard({ now, layoutChangedAt: expectedRevision == null ? layoutChangedAt : 0, lastPress, key });
  if (blocked) return { ok: false, ignored: blocked };
  lastPress = { key, at: now };
  if (expectedRevision == null && layoutBefore && status.layoutMode !== layoutBefore) return { ok: false, ignored: 'layout' };
  const tile = tileForKey(key, status);
  if (!tile || tile.enabled === false) return { ok: false, ignored: 'disabled' };
  console.log(`[press] key=${key} action=${tile.action} target=${tile.target || '-'}`);
  return execute(tile.action, tile.target);
}

function localOrigin(req) {
  const origin = req.headers.origin || '';
  if (origin === `http://127.0.0.1:${PORT}` || origin === `http://localhost:${PORT}`) return origin;
  return '';
}

function readBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', (chunk) => {
      if (body.length < 65536) body += chunk;
    });
    req.on('end', () => {
      if (!body.trim()) return resolve({});
      try { resolve(JSON.parse(body)); } catch { resolve({}); }
    });
  });
}

function send(res, status, payload, type = 'application/json') {
  const body = type === 'application/json' ? JSON.stringify(payload) : payload;
  res.writeHead(status, { 'Content-Type': type });
  res.end(body);
}

async function perform(task, key = '') {
  return enqueueAction(async () => {
    let result;
    try { result = await task(); }
    catch (err) { result = { ok: false, error: err.message }; }
    const message = result.error || (result.ignored ? `Press ignored: ${result.ignored}` : 'Action completed');
    lastAction = { ...result, key, message, timestamp: Date.now() };
    if (result.error) noteError(result.error);
    else if (result.ok) lastError = '';
    console.log(`[result] key=${key} ${JSON.stringify(result)}`);
    return result;
  });
}

const server = http.createServer(async (req, res) => {
  if (!isLocalHost(req.headers.host)) {
    send(res, 403, { ok: false, error: 'Localhost only' });
    return;
  }

  const origin = localOrigin(req);
  if (origin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Agent-Deck');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Vary', 'Origin');
  }
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url || '/', `http://127.0.0.1:${PORT}`);
  const parts = url.pathname.split('/').filter(Boolean);

  if (req.method === 'GET' && parts.length === 0) {
    send(res, 200, dashboardHtml(), 'text/html; charset=utf-8');
    return;
  }
  if (req.method === 'GET' && parts[0] === 'status') {
    send(res, 200, publicStatus());
    return;
  }
  if (req.method !== 'POST' || req.headers[HEADER] !== '1') {
    send(res, 403, { ok: false, error: 'Missing X-Agent-Deck header' });
    return;
  }

  if (parts[0] === 'hook') {
    const body = await readBody(req);
    const session = applyHook(parts[1] || 'claude', parts[2] || '', body);
    send(res, 200, { ok: true, session: session?.id || session?.removed || '' });
    return;
  }
  if (parts[0] === 'press') {
    const key = decodeURIComponent(parts[1] || '');
    const body = await readBody(req);
    send(res, 200, await perform(() => handlePress(key, body.revision), key));
    return;
  }
  if (parts[0] === 'dial' && parts[1] === 'turn') {
    const ids = cycleIds(sessions);
    selectedSessionId = nextSelection(ids, selectedSessionId, Number(url.searchParams.get('delta') || 1));
    send(res, 200, { ok: true, selectedSessionId });
    return;
  }
  if (parts[0] === 'dial' && parts[1] === 'press') {
    const body = await readBody(req);
    const session = sessions.get(body.sessionId || selectedSessionId);
    if (!session) {
      send(res, 200, { ok: false, error: 'No agent selected' });
      return;
    }
    console.log(`[press] key=dial action=focus target=${session.id}`);
    send(res, 200, await perform(() => execute('focus', session.id), 'dial'));
    return;
  }
  if (parts[0] === 'action') {
    const target = decodeURIComponent(parts[1] || '');
    const action = (parts[2] || 'focus').toLowerCase();
    console.log(`[press] key=api action=${action} target=${target || '-'}`);
    send(res, 200, await perform(() => execute(action, target), 'api'));
    return;
  }
  send(res, 404, { ok: false, error: 'Not found' });
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`[ai-agent-deck] Port ${PORT} is already in use. A daemon is already running, so this one is stopping.`);
    process.exit(0);
  }
  console.error('[ai-agent-deck] Server error:', err);
  process.exit(1);
});

export function start() {
  try {
    const saved = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    for (const session of Object.values(saved.sessions || {})) {
      if (session?.id && session.agentId && (session.agentId === 'cursor' || pidAlive(session.pid))) sessions.set(session.id, session);
    }
    selectedSessionId = saved.selectedSessionId || '';
  } catch {}
  const save = () => {
    try {
      fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
      fs.writeFileSync(STATE_FILE + '.tmp', JSON.stringify({sessions: Object.fromEntries(sessions), selectedSessionId}), { mode: 0o600 });
      fs.renameSync(STATE_FILE + '.tmp', STATE_FILE);
    } catch (err) { noteError(`Could not save sessions: ${err.message}`); }
  };
  setInterval(save, 5000).unref();
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => { save(); process.exit(0); });
  setInterval(() => { scan(); }, 1000);
  scan();
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`[ai-agent-deck] daemon on http://127.0.0.1:${PORT}`);
  });
}

if (import.meta.main) start();
