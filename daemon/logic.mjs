import path from 'node:path';

export const AGENTS = {
  antigravity: { name: 'Antigravity', shortName: 'AGY', color: '#38bdf8' },
  claude: { name: 'Claude Code', shortName: 'CLAUDE', color: '#f97316' },
  cursor: { name: 'Cursor', shortName: 'CURSOR', color: '#a855f7' },
  gemini: { name: 'Gemini CLI', shortName: 'GEMINI', color: '#3b82f6' },
  codex: { name: 'Codex', shortName: 'CODEX', color: '#10b981' },
};

const TERMINAL_AGENTS = new Set(['claude', 'gemini', 'codex']);
const PRIORITY = { WAITING: 5, ERROR: 4, WORKING: 3, DONE: 2, IDLE: 1, OFF: 0 };
const BUNDLE_ID = /^[A-Za-z0-9.-]+$/;

export function agentMeta(agentId) {
  const id = String(agentId || '').toLowerCase();
  return AGENTS[id] || {
    name: id ? id.toUpperCase() : 'AGENT',
    shortName: (id || 'agent').slice(0, 6).toUpperCase(),
    color: '#38bdf8',
  };
}

export function isTerminalAgent(agentId) {
  return TERMINAL_AGENTS.has(String(agentId || '').toLowerCase());
}

/** Return selects the default Yes on Claude and Gemini. Codex accepts y. */
export function approveKey(agentId) {
  const id = String(agentId || '').toLowerCase();
  if (id === 'codex') return 'y';
  if (id === 'claude' || id === 'gemini' || id === 'antigravity') return 'return';
  return null;
}

export function slug(value) {
  const text = String(value || 'main').toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 16);
  return text || 'main';
}

/** Cursor's Window menu is "file — folder". The folder matches the hook's cwd basename. */
export function cursorWorkspace(title) {
  const text = String(title || '').replace(/\s+[—–]\s+The following extensions want to relaunch[\s\S]*$/i, '').replace(/^Cursor\s+/i, '').trim();
  const em = text.split(/\s+[—–]\s+/);
  if (em.length >= 2 && em.at(-1).trim()) return em.at(-1).trim();
  const hy = text.split(/\s+-\s+/);
  if (hy.length >= 2 && hy.at(-1).trim()) return hy.at(-1).trim();
  return text || 'main';
}

export function sessionId(agentId, workspace) {
  return `${String(agentId || 'agent').toLowerCase()}:${slug(workspace)}`;
}

export function safeBundleId(value) {
  const text = String(value || '');
  return BUNDLE_ID.test(text) ? text : '';
}

export function pidAlive(pid) {
  const n = Number(pid);
  if (!n || n <= 0) return false;
  try {
    process.kill(n, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

export function isLocalHost(hostHeader) {
  const host = String(hostHeader || '').trim().replace(/:\d+$/, '');
  return host === '127.0.0.1' || host === 'localhost';
}

/** The hook wraps the agent's JSON in `data` and its own cwd in `env`. Prefer the agent payload. */
export function readHook(body) {
  const root = body && typeof body === 'object' ? body : {};
  const data = root.data && typeof root.data === 'object' ? root.data : root;
  const env = root.env && typeof root.env === 'object' ? root.env : {};
  const tool = data.tool_name || data.toolName || data.tool || data.command || '';
  const roots = Array.isArray(data.workspace_roots) ? data.workspace_roots[0] : '';
  const cwd = data.cwd || roots || env.pwd || '';
  const base = path.basename(String(cwd).replace(/[/\\]+$/, '')) || 'main';
  const pid = Number(env.ppid || data.pid || 0) || 0;
  return {
    tool: String(tool).slice(0, 48),
    cwd: String(cwd),
    workspace: base,
    pid,
    bundleId: safeBundleId(env.bundleId),
    tty: String(env.tty || ''),
    terminalId: String(env.terminalId || ''),
    agentSessionId: String(data.session_id || data.sessionId || ''),
  };
}

function eventKey(eventName) {
  return String(eventName || '').toLowerCase().replace(/[^a-z]/g, '');
}

function fill(template, tool) {
  const name = String(tool || '').trim().slice(0, 24) || 'tool';
  return template.replaceAll('{tool}', name);
}

function permissionNotification(data) {
  const source = data && typeof data === 'object' ? data : {};
  const blob = [source.notification_type, source.notificationType, source.type, source.message, source.title, source.detail]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
  return blob.includes('permission') || blob.includes('approval') || blob.includes('approve');
}

function hasError(data) {
  if (!data || typeof data !== 'object') return false;
  if (data.error || data.is_error === true) return true;
  const reason = String(data.terminationReason || data.termination_reason || '').toUpperCase();
  return reason === 'ERROR';
}

function canceled(data) {
  const reason = String(data?.terminationReason || data?.termination_reason || '').toUpperCase();
  return reason === 'USER_CANCELED' || reason === 'USER_CANCELLED';
}

/**
 * Exact event names only. Substrings such as "prompt" must not mean "waiting for approval".
 * @returns {{ignore?: true, remove?: true, status?: string, detail?: string}}
 */
export function classifyEvent(eventName, data = {}) {
  const ev = eventKey(eventName);
  const tool = data?.tool_name || data?.toolName || data?.tool || data?.command || '';

  if (ev === 'notification') {
    if (permissionNotification(data)) return { status: 'WAITING', detail: 'Needs approval' };
    return { ignore: true };
  }

  const table = {
    sessionstart: ['IDLE', 'Ready'],
    userpromptsubmit: ['WORKING', 'Thinking...'],
    beforesubmitprompt: ['WORKING', 'Thinking...'],
    preinvocation: ['WORKING', 'Thinking...'],
    beforeagent: ['WORKING', 'Thinking...'],
    pretooluse: ['WORKING', 'Tool: {tool}'],
    beforetool: ['WORKING', 'Tool: {tool}'],
    beforeshell: ['WORKING', 'Tool: {tool}'],
    beforemcp: ['WORKING', 'Tool: {tool}'],
    posttooluse: ['WORKING', 'Done: {tool}'],
    aftertool: ['WORKING', 'Done: {tool}'],
    aftershell: ['WORKING', 'Done: {tool}'],
    aftermcpexecution: ['WORKING', 'Done: {tool}'],
    aftershellexecution: ['WORKING', 'Done: {tool}'],
    afterfileedit: ['WORKING', 'Editing files'],
    permissionrequest: ['WAITING', 'Approve {tool}?'],
    stop: ['DONE', 'Task finished'],
    afteragent: ['DONE', 'Task finished'],
    turnended: ['DONE', 'Task finished'],
    sessionend: 'REMOVE',
  };

  const row = table[ev];
  if (!row) return { ignore: true };
  if (row === 'REMOVE') return { remove: true };

  if ((ev === 'stop' || ev === 'afteragent' || ev === 'turnended') && hasError(data)) {
    return { status: 'ERROR', detail: 'Error' };
  }
  if ((ev === 'stop' || ev === 'afteragent' || ev === 'turnended') && canceled(data)) {
    return { status: 'IDLE', detail: 'Canceled' };
  }
  if ((ev === 'posttooluse' || ev === 'aftertool' || ev === 'aftershellexecution' || ev === 'aftermcpexecution') && hasError(data)) {
    return { status: 'ERROR', detail: fill('Error in {tool}', tool) };
  }

  return { status: row[0], detail: fill(row[1], tool) };
}

/** Allow and deny act only on a session that is actually waiting. No fallback. */
export function resolveApproval(sessions, targetId) {
  if (targetId && targetId !== 'all') {
    const session = sessions.get(targetId);
    return session && session.status === 'WAITING' ? session : null;
  }
  for (const session of sessions.values()) {
    if (session.status === 'WAITING') return session;
  }
  return null;
}

/** Stop sends Ctrl+C, which only makes sense in a terminal agent. */
export function resolveStop(sessions, targetId) {
  if (!targetId || targetId === 'all') return null;
  const session = sessions.get(targetId);
  if (!session || !isTerminalAgent(session.agentId)) return null;
  return session;
}

export function byPriority(a, b) {
  return (PRIORITY[b.status] || 0) - (PRIORITY[a.status] || 0) || (b.updatedAt || 0) - (a.updatedAt || 0);
}

export function applyTimeouts(sessions, now) {
  let changed = false;
  for (const session of sessions.values()) {
    const idleFor = now - (session.updatedAt || 0);
    if (session.status === 'WORKING' && idleFor > 10 * 60 * 1000) {
      session.status = 'IDLE';
      session.detail = 'Ready';
      changed = true;
    } else if (session.status === 'DONE' && idleFor > 15 * 60 * 1000) {
      session.status = 'IDLE';
      session.detail = 'Ready';
      changed = true;
    }
  }
  return changed;
}

export function activeSessions(all, now) {
  return all.filter((session) => session.status !== 'IDLE' || (session.lastHookAt > 0 && now - session.lastHookAt < 15 * 60 * 1000));
}

function offTile(key, label) {
  return {
    type: 'instance',
    key,
    target: '',
    action: 'focus',
    label,
    sublabel: 'OFF',
    detail: 'Closed',
    status: 'OFF',
    color: '#334155',
    enabled: false,
    agent: label,
    workspace: 'OFF',
  };
}

function instanceTile(key, session, selectedId) {
  return {
    type: 'instance',
    key,
    target: session.id,
    action: 'focus',
    label: session.shortName,
    sublabel: session.instanceLabel,
    detail: session.status === 'WAITING' || session.status === 'ERROR'
      ? (session.detail || session.tool || session.status)
      : (session.tool || session.detail || 'Ready'),
    status: session.status,
    color: session.accentColor,
    enabled: true,
    isSelected: session.id === selectedId,
    agent: session.shortName,
    workspace: session.instanceLabel,
  };
}

export function buildTiles({ sessions, selectedId, forceMulti, now }) {
  const all = [...sessions.values()].sort(byPriority);
  const active = activeSessions(all, now);
  const single = !forceMulti && active.length === 1;
  const layoutMode = single ? 'single_agent' : 'multi_instance';
  const workingCount = all.filter((session) => session.status === 'WORKING').length;
  const waitingCount = all.filter((session) => session.status === 'WAITING').length;
  const doneCount = all.filter((session) => session.status === 'DONE').length;
  const errorCount = all.filter((session) => session.status === 'ERROR').length;
  const top = all[0] || null;
  let selected = selectedId;
  if (!selected || !sessions.has(selected)) selected = top ? top.id : '';

  const tiles = [];
  if (single) {
    const session = active[0];
    const waiting = session.status === 'WAITING';
    tiles.push(
      instanceTile('antigravity', session, selected),
      {
        type: 'tool',
        key: 'claude',
        target: session.id,
        action: 'focus',
        label: 'TOOL',
        sublabel: session.tool || 'idle',
        detail: session.tool || session.detail || 'idle',
        status: session.status,
        color: '#818cf8',
        enabled: true,
      },
      {
        type: 'repo',
        key: 'cursor',
        target: session.id,
        action: 'focus',
        label: 'WORKSPACE',
        sublabel: session.instanceLabel,
        detail: session.workspace,
        status: 'IDLE',
        color: '#34d399',
        enabled: true,
      },
      {
        type: 'action',
        key: 'gemini',
        target: session.id,
        action: 'focus',
        label: 'FOCUS',
        sublabel: 'WINDOW',
        detail: 'Bring to front',
        status: 'IDLE',
        color: '#38bdf8',
        enabled: true,
      },
      {
        type: 'action',
        key: 'codex',
        target: session.id,
        action: 'stop',
        label: 'STOP',
        sublabel: 'INTERRUPT',
        detail: 'Ctrl+C',
        status: 'IDLE',
        color: '#eab308',
        enabled: isTerminalAgent(session.agentId),
      },
      {
        type: 'grid',
        key: 'summary',
        target: 'all',
        action: 'toggle_mode',
        label: 'GRID',
        sublabel: 'ALL',
        detail: 'All agents',
        status: 'IDLE',
        color: '#64748b',
        enabled: true,
      },
      {
        type: 'action',
        key: 'approve',
        target: session.id,
        action: 'approve',
        label: 'ALLOW',
        sublabel: 'CONFIRM',
        detail: waiting ? (session.detail || session.tool || 'Approve') : 'Ready',
        status: waiting ? 'WAITING' : 'IDLE',
        color: '#10b981',
        enabled: waiting,
      },
      {
        type: 'action',
        key: 'deny',
        target: session.id,
        action: 'deny',
        label: 'DENY',
        sublabel: 'CANCEL',
        detail: 'Cancel',
        status: waiting ? 'WAITING' : 'IDLE',
        color: '#ef4444',
        enabled: waiting,
      },
      {
        type: 'action',
        key: 'dashboard',
        target: 'all',
        action: 'dashboard',
        label: 'DECK',
        sublabel: 'MISSION',
        detail: 'Open dashboard',
        status: 'IDLE',
        color: '#0284c7',
        enabled: true,
      },
    );
  } else {
    const agy = all.find((session) => session.agentId === 'antigravity');
    const cursors = all.filter((session) => session.agentId === 'cursor')
      .sort((a, b) => (b.status === 'WORKING') - (a.status === 'WORKING') || a.workspace.localeCompare(b.workspace));
    const mainCursor = cursors[0];
    const claude = all.find((session) => session.agentId === 'claude');
    const gemini = all.find((session) => session.agentId === 'gemini');
    const codex = all.find((session) => session.agentId === 'codex');
    const used = new Set([agy, mainCursor, claude, gemini, codex].filter(Boolean));
    const extras = all.filter((session) => !used.has(session));
    const topWaiting = all.find((session) => session.status === 'WAITING');

    const place = (key, session, offLabel, allowExtra) => {
      if (session) tiles.push(instanceTile(key, session, selected));
      else if (allowExtra && extras.length) tiles.push(instanceTile(key, extras.shift(), selected));
      else tiles.push(offTile(key, offLabel));
    };

    place('antigravity', agy, 'AGY', false);
    place('claude', claude, 'CLAUDE', true);
    place('cursor', mainCursor, 'CURSOR', false);
    place('gemini', gemini, 'GEMINI', true);
    place('codex', codex, 'CODEX', true);

    tiles.push({
      type: 'summary',
      key: 'summary',
      target: 'all',
      action: 'toggle_mode',
      label: 'AGENTS',
      sublabel: `${all.length}`,
      detail: waitingCount > 0 ? `${waitingCount} waiting` : `${workingCount} working`,
      status: waitingCount > 0 ? 'WAITING' : (workingCount > 0 ? 'WORKING' : 'IDLE'),
      color: '#6366f1',
      enabled: true,
      count: all.length,
      working: workingCount,
      waiting: waitingCount,
    });
    tiles.push({
      type: 'action',
      key: 'approve',
      target: topWaiting?.id || '',
      action: 'approve',
      label: 'ALLOW',
      sublabel: 'CONFIRM',
      detail: topWaiting ? (topWaiting.detail || topWaiting.tool || 'Approve') : 'Ready',
      status: topWaiting ? 'WAITING' : 'IDLE',
      color: '#10b981',
      enabled: Boolean(topWaiting),
    });
    tiles.push({
      type: 'action',
      key: 'deny',
      target: topWaiting?.id || '',
      action: 'deny',
      label: 'DENY',
      sublabel: 'CANCEL',
      detail: 'Cancel',
      status: topWaiting ? 'WAITING' : 'IDLE',
      color: '#ef4444',
      enabled: Boolean(topWaiting),
    });
    tiles.push({
      type: 'action',
      key: 'dashboard',
      target: 'all',
      action: 'dashboard',
      label: 'DECK',
      sublabel: 'MISSION',
      detail: 'Open dashboard',
      status: 'IDLE',
      color: '#0284c7',
      enabled: true,
    });
  }

  const dialSession = selected ? sessions.get(selected) : null;
  const dial = dialSession
    ? instanceTile('dial', dialSession, selected)
    : {
      type: 'instance',
      key: 'dial',
      target: '',
      action: 'focus',
      label: 'DECK',
      sublabel: 'OFF',
      detail: 'No agent',
      status: 'OFF',
      color: '#334155',
      enabled: false,
      agent: 'DECK',
      workspace: 'OFF',
    };

  const headline = waitingCount > 0
    ? `${waitingCount} WAITING APPROVAL`
    : (workingCount > 0 ? `${workingCount} WORKING` : (all.length ? 'ALL AGENTS READY' : 'NO AGENTS'));

  return {
    layoutMode,
    selectedSessionId: selected,
    tiles,
    dial,
    summary: { workingCount, waitingCount, doneCount, errorCount, headline },
  };
}

export function cycleIds(sessions) {
  return [...sessions.values()]
    .sort((a, b) => a.agentId.localeCompare(b.agentId) || String(a.workspace).localeCompare(String(b.workspace)))
    .map((session) => session.id);
}

export function nextSelection(ids, selected, delta) {
  if (!ids.length) return '';
  let index = ids.indexOf(selected);
  if (index < 0) index = 0;
  const step = Number(delta) || 1;
  return ids[(index + step + ids.length * 8) % ids.length];
}

/** Empty string means the press is allowed. Otherwise the reason it is dropped. */
export function pressGuard({ now, layoutChangedAt, lastPress, key }) {
  if (layoutChangedAt && now - layoutChangedAt < 800) return 'layout';
  if (lastPress && lastPress.key === key && now - lastPress.at < 300) return 'debounce';
  return '';
}
