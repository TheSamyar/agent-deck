export function dashboardHtml() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>AI Agent Deck</title>
<style>
  :root { color-scheme: dark; --bg: #07090e; --text: #f8fafc; --muted: #94a3b8; --line: #1e293b; --card: #0f141f; }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; }
  main { max-width: 920px; margin: 0 auto; padding: 28px 20px 48px; }
  header { display: flex; justify-content: space-between; gap: 16px; align-items: flex-end; margin-bottom: 18px; }
  h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -0.02em; }
  h2 { font-size: 13px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); margin: 28px 0 10px; }
  p { margin: 0; color: var(--muted); font-size: 13px; }
  .badge { border: 1px solid #1e3a4c; background: #0b1b27; color: #7dd3fc; border-radius: 999px; padding: 6px 12px; font-size: 12px; font-weight: 700; white-space: nowrap; }
  .banner { display: none; background: #3f1212; color: #fecaca; border-radius: 10px; padding: 10px 12px; margin-bottom: 16px; font-size: 13px; }
  .keypad { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; max-width: 480px; }
  .key { padding: 0; border: 0; background: transparent; cursor: pointer; border-radius: 18px; }
  .key svg { width: 100%; height: auto; display: block; }
  .key:focus-visible { outline: 2px solid #38bdf8; outline-offset: 3px; }
  .sessions, .events { display: flex; flex-direction: column; gap: 8px; }
  .row { display: grid; grid-template-columns: minmax(0, 1.4fr) auto minmax(0, 1.6fr) auto; gap: 10px; align-items: center; background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 10px 12px; }
  .name { font-weight: 700; }
  .detail, .event { color: var(--muted); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .status { font-size: 11px; font-weight: 800; letter-spacing: 0.04em; border-radius: 999px; padding: 3px 8px; background: #172033; }
  .WAITING { color: #fde68a; }
  .WORKING { color: #93c5fd; }
  .DONE { color: #6ee7b7; }
  .ERROR { color: #fca5a5; }
  .actions { display: flex; gap: 6px; }
  button.act { background: #172033; color: var(--text); border: 1px solid #334155; border-radius: 8px; padding: 6px 10px; font-weight: 700; font-size: 12px; cursor: pointer; }
  button.act:hover { border-color: #64748b; }
  .event-row { display: grid; grid-template-columns: 88px 120px minmax(0, 1fr); gap: 10px; font-size: 13px; }
  .time { color: var(--muted); font-variant-numeric: tabular-nums; }
  @media (max-width: 640px) {
    .row, .event-row { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>AI Agent Deck</h1>
      <p id="mode">Mission control</p>
    </div>
    <div id="headline" class="badge">Connecting</div>
  </header>
  <div id="banner" class="banner" role="status"></div>
  <h2>Keypad</h2>
  <div id="keypad" class="keypad"></div>
  <h2>Sessions</h2>
  <div id="sessions" class="sessions"></div>
  <h2>Recent</h2>
  <div id="events" class="events"></div>
</main>
<script>
const headline = document.getElementById('headline');
const mode = document.getElementById('mode');
const banner = document.getElementById('banner');
const keypad = document.getElementById('keypad');
const sessionsEl = document.getElementById('sessions');
const eventsEl = document.getElementById('events');

function showError(text) {
  banner.style.display = text ? 'block' : 'none';
  banner.textContent = text || '';
}

let revision = null;
let actionErrorUntil = 0;
async function post(path) {
  const res = await fetch(path, { method: 'POST', headers: { 'X-Agent-Deck': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ revision }) });
  const result = await res.json();
  if (!res.ok || !result.ok) {
    actionErrorUntil = Date.now() + 8000;
    throw new Error(result.error || ('Press ignored: ' + (result.ignored || 'unknown error')));
  }
  actionErrorUntil = 0;
  refresh();
}

function pressButton() {
  const button = document.createElement('button');
  button.className = 'key';
  button.type = 'button';
  button.addEventListener('click', () => {
    post('/press/' + encodeURIComponent(button.dataset.key || '')).catch((err) => showError(err.message));
  });
  return button;
}

function sessionRow(session) {
  const row = document.createElement('div');
  row.className = 'row';
  const name = document.createElement('div');
  name.className = 'name';
  name.textContent = session.shortName + '  ' + (session.instanceLabel || session.workspace || '');
  const status = document.createElement('div');
  status.className = 'status ' + (session.status || '');
  status.textContent = session.status || '';
  const detail = document.createElement('div');
  detail.className = 'detail';
  const waiting = session.status === 'WAITING' || session.status === 'ERROR';
  detail.textContent = waiting ? (session.detail || session.tool || 'Waiting') : (session.tool || session.detail || 'Ready');
  const actions = document.createElement('div');
  actions.className = 'actions';
  const focus = document.createElement('button');
  focus.className = 'act';
  focus.type = 'button';
  focus.textContent = 'Focus';
  focus.addEventListener('click', () => post('/action/' + encodeURIComponent(session.id) + '/focus').catch((err) => showError(err.message)));
  actions.append(focus);
  if (session.status === 'WAITING') {
    const allow = document.createElement('button');
    allow.className = 'act';
    allow.type = 'button';
    allow.textContent = 'Allow';
    allow.addEventListener('click', () => post('/action/' + encodeURIComponent(session.id) + '/approve').catch((err) => showError(err.message)));
    const deny = document.createElement('button');
    deny.className = 'act';
    deny.type = 'button';
    deny.textContent = 'Deny';
    deny.addEventListener('click', () => post('/action/' + encodeURIComponent(session.id) + '/deny').catch((err) => showError(err.message)));
    actions.append(allow, deny);
  }
  row.append(name, status, detail, actions);
  return row;
}

let sessionStamp = '';
let eventStamp = '';

function render(data) {
  revision = data.revision;
  if (Date.now() > actionErrorUntil) showError(data.lastError || '');
  headline.textContent = data.summary.headline;
  mode.textContent = data.layoutMode === 'single_agent' ? 'One agent on the keypad' : 'All agents on the keypad';
  const tiles = data.tiles || [];
  if (keypad.children.length !== tiles.length) {
    keypad.replaceChildren();
    for (let i = 0; i < tiles.length; i++) keypad.append(pressButton());
  }
  tiles.forEach((tile, index) => {
    const button = keypad.children[index];
    const svg = String(tile.svg || '').replaceAll('{{size}}', '160');
    button.dataset.key = tile.key || '';
    button.disabled = tile.enabled === false;
    button.setAttribute('aria-label', [tile.label, tile.detail].filter(Boolean).join(' '));
    if (button.dataset.svg !== svg) {
      button.dataset.svg = svg;
      button.innerHTML = svg;
    }
  });
  const sessions = Object.values(data.sessions || {});
  const nextSessions = JSON.stringify(sessions.map((session) => [session.id, session.status, session.detail, session.tool, session.instanceLabel]));
  if (nextSessions === sessionStamp) {
    renderEvents(data);
    return;
  }
  sessionStamp = nextSessions;
  sessionsEl.replaceChildren();
  if (!sessions.length) {
    const empty = document.createElement('p');
    empty.textContent = 'No agents running.';
    sessionsEl.append(empty);
  } else {
    for (const session of sessions) sessionsEl.append(sessionRow(session));
  }
  renderEvents(data);
}

function renderEvents(data) {
  const nextEvents = JSON.stringify(data.recentEvents || []);
  if (nextEvents === eventStamp) return;
  eventStamp = nextEvents;
  eventsEl.replaceChildren();
  for (const event of data.recentEvents || []) {
    const row = document.createElement('div');
    row.className = 'event-row';
    const time = document.createElement('div');
    time.className = 'time';
    time.textContent = event.time || '';
    const who = document.createElement('div');
    who.textContent = event.sessionId || '';
    const what = document.createElement('div');
    what.className = 'event';
    what.textContent = (event.eventName || '') + '  ' + (event.detail || '');
    row.append(time, who, what);
    eventsEl.append(row);
  }
}

async function refresh() {
  try {
    const res = await fetch('/status');
    if (!res.ok) throw new Error('Status unavailable');
    render(await res.json());
  } catch (err) {
    showError(err.message || 'Daemon unreachable');
  }
}
setInterval(refresh, 800);
refresh();
</script>
</body>
</html>`;
}
