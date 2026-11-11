const FONT = "'Helvetica Neue', Helvetica, Arial, sans-serif";

const ACTIONS = {
  approve: { bg: '#022c22', border: '#10b981', title: '#6ee7b7', accent: '#34d399', caption: '#a7f3d0', icon: 'allow' },
  deny: { bg: '#2a0c0c', border: '#ef4444', title: '#fca5a5', accent: '#f87171', caption: '#fecaca', icon: 'deny' },
  stop: { bg: '#241a05', border: '#eab308', title: '#fde047', accent: '#facc15', caption: '#fef08a', icon: 'stop' },
  focus: { bg: '#082f49', border: '#38bdf8', title: '#7dd3fc', accent: '#38bdf8', caption: '#bae6fd', icon: 'focus' },
  dashboard: { bg: '#082f49', border: '#0284c7', title: '#7dd3fc', accent: '#38bdf8', caption: '#bae6fd', icon: 'deck' },
};

export function xmlEscape(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&apos;',
  }[ch]));
}

export function safeColor(value, fallback) {
  return /^#[0-9a-fA-F]{6}$/.test(value || '') ? value : fallback;
}

/** Shrink the font, then ellipsize, so a long repo name stays inside the key. */
export function fitLabel(value, maxChars, baseSize) {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim();
  const max = Math.max(1, maxChars);
  if (text.length <= max) return { text, size: baseSize };
  const small = Math.max(7, baseSize - 2);
  const wider = max + 4;
  if (text.length <= wider) return { text, size: small };
  return { text: `${text.slice(0, wider - 1)}…`, size: small };
}

function gid(key) {
  return `k${String(key || 'x').replace(/[^a-zA-Z0-9]/g, '')}`;
}

function text(value, x, y, size, fill, weight = 700) {
  const fitted = fitLabel(value, size >= 12 ? 12 : 18, size);
  return `<text x="${x}" y="${y}" text-anchor="middle" fill="${fill}" font-size="${fitted.size}" font-family="${FONT}" font-weight="${weight}" letter-spacing="0.3">${xmlEscape(fitted.text)}</text>`;
}

function pill(value, fill) {
  const fitted = fitLabel(value, 16, 8);
  return `<rect x="8" y="78" width="84" height="16" rx="8" fill="#0b1220" fill-opacity="0.92"/>
    <text x="50" y="89" text-anchor="middle" fill="${fill}" font-size="${fitted.size}" font-family="${FONT}" font-weight="700">${xmlEscape(fitted.text)}</text>`;
}

function icon(name, x, y) {
  const glyphs = {
    allow: `<circle cx="12" cy="12" r="11" fill="#34d399"/>
      <path d="M7 12.4 L10.4 16 L17.2 8.4" fill="none" stroke="#064e3b" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>`,
    deny: `<circle cx="12" cy="12" r="11" fill="#f87171"/>
      <path d="M8 8 L16 16 M16 8 L8 16" fill="none" stroke="#7f1d1d" stroke-width="2.4" stroke-linecap="round"/>`,
    stop: `<circle cx="12" cy="12" r="11" fill="#facc15"/>
      <rect x="8" y="8" width="8" height="8" rx="1.4" fill="#422006"/>`,
    focus: `<circle cx="12" cy="12" r="5.5" fill="none" stroke="#7dd3fc" stroke-width="1.8"/>
      <circle cx="12" cy="12" r="1.7" fill="#7dd3fc"/>
      <path d="M12 2.5 V6.2 M12 17.8 V21.5 M2.5 12 H6.2 M17.8 12 H21.5" fill="none" stroke="#7dd3fc" stroke-width="1.6" stroke-linecap="round"/>`,
    deck: `<circle cx="12" cy="12" r="8" fill="#0284c7"/>
      <ellipse cx="12" cy="12" rx="3.4" ry="8" fill="none" stroke="#e0f2fe" stroke-width="1.2"/>
      <path d="M4 12 H20 M6.2 8 H17.8 M6.2 16 H17.8" fill="none" stroke="#e0f2fe" stroke-width="1.1"/>`,
    tool: `<path d="M5 8 L11 12 L5 16" fill="none" stroke="#c7d2fe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M13 16 H20" fill="none" stroke="#c7d2fe" stroke-width="2" stroke-linecap="round"/>`,
    folder: `<path d="M2 7 H10 L12 9 H22 V19 H2 Z" fill="#064e3b" stroke="#6ee7b7" stroke-width="1.5" stroke-linejoin="round"/>`,
    grid: `<rect x="3" y="3" width="7.5" height="7.5" rx="1.6" fill="#cbd5e1"/>
      <rect x="13.5" y="3" width="7.5" height="7.5" rx="1.6" fill="#cbd5e1"/>
      <rect x="3" y="13.5" width="7.5" height="7.5" rx="1.6" fill="#cbd5e1"/>
      <rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.6" fill="#cbd5e1"/>`,
  };
  return `<g transform="translate(${x} ${y})">${glyphs[name] || glyphs.grid}</g>`;
}

function shell({ id, bg, glow, glowOpacity, border, borderWidth, dim, defs = '', body }) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="{{size}}" height="{{size}}" viewBox="0 0 100 100">
  <defs>
    <radialGradient id="${id}glow" cx="50%" cy="42%" r="62%">
      <stop offset="0%" stop-color="${glow}" stop-opacity="${glowOpacity}"/>
      <stop offset="100%" stop-color="${bg}" stop-opacity="0"/>
    </radialGradient>
    ${defs}
  </defs>
  <rect width="100" height="100" rx="18" fill="${bg}"/>
  <rect width="100" height="100" rx="18" fill="url(#${id}glow)"/>
  <rect x="1.5" y="1.5" width="97" height="97" rx="16.5" fill="none" stroke="${border}" stroke-width="${borderWidth}"/>
  <g opacity="${dim ? 0.38 : 1}">
    ${body}
  </g>
</svg>`;
}

function orbColors(status, accent) {
  switch (status) {
    case 'WORKING': return { mid: accent, dark: '#0f172a', halo: 0.5 };
    case 'WAITING': return { mid: '#f59e0b', dark: '#78350f', halo: 0.62 };
    case 'DONE': return { mid: '#10b981', dark: '#064e3b', halo: 0.4 };
    case 'ERROR': return { mid: '#ef4444', dark: '#7f1d1d', halo: 0.45 };
    case 'OFF': return { mid: '#334155', dark: '#0f172a', halo: 0 };
    default: return { mid: '#64748b', dark: '#1e293b', halo: 0.16 };
  }
}

function orbMarkup(id, status, accent, frame) {
  const colors = orbColors(status, accent);
  const cx = 50;
  const cy = 56;
  const r = 11;
  let extra = '';
  if (status === 'WORKING') {
    const ring = r * 1.7;
    const angle = frame * (Math.PI / 2);
    const sx = cx + Math.cos(angle) * ring;
    const sy = cy + Math.sin(angle) * ring;
    extra = `<circle cx="${cx}" cy="${cy}" r="${ring.toFixed(1)}" fill="none" stroke="${colors.mid}" stroke-width="1.5" stroke-dasharray="3.5 3"/>
      <circle cx="${sx.toFixed(1)}" cy="${sy.toFixed(1)}" r="2.4" fill="#ffffff"/>`;
  } else if (status === 'WAITING') {
    const ring = r * 1.45 + frame * 1.6;
    const opacity = (0.9 - frame * 0.18).toFixed(2);
    extra = `<circle cx="${cx}" cy="${cy}" r="${ring.toFixed(1)}" fill="none" stroke="#fbbf24" stroke-width="2" stroke-opacity="${opacity}"/>
      <text x="${cx}" y="${cy + 5}" text-anchor="middle" fill="#78350f" font-size="14" font-family="${FONT}" font-weight="800">!</text>`;
  } else if (status === 'DONE') {
    extra = `<path d="M ${cx - 5} ${cy} L ${cx - 1.5} ${cy + 3.6} L ${cx + 5.5} ${cy - 4}" fill="none" stroke="#064e3b" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>`;
  } else if (status === 'ERROR') {
    extra = `<path d="M ${cx - 3.6} ${cy - 3.6} L ${cx + 3.6} ${cy + 3.6} M ${cx + 3.6} ${cy - 3.6} L ${cx - 3.6} ${cy + 3.6}" fill="none" stroke="#7f1d1d" stroke-width="2" stroke-linecap="round"/>`;
  }
  return {
    colors,
    body: `<circle cx="${cx}" cy="${cy}" r="${(r * 1.9).toFixed(1)}" fill="${colors.mid}" fill-opacity="${colors.halo}"/>
      <circle cx="${cx}" cy="${cy}" r="${r}" fill="url(#${id}orb)"/>
      ${extra}`,
    defs: `<radialGradient id="${id}orb" cx="35%" cy="32%" r="68%">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="46%" stop-color="${colors.mid}"/>
      <stop offset="100%" stop-color="${colors.dark}"/>
    </radialGradient>`,
  };
}

function renderInstance(tile, frame) {
  const id = gid(tile.key);
  const accent = safeColor(tile.color, '#38bdf8');
  const status = tile.status || 'IDLE';
  const off = status === 'OFF';
  const selected = Boolean(tile.isSelected) && !off;
  const orb = orbMarkup(id, status, accent, frame);
  const border = selected || status === 'WORKING' || status === 'WAITING' ? (status === 'WAITING' ? '#fbbf24' : accent) : '#1e293b';
  const agentFill = off ? '#64748b' : accent;
  const nameFill = off ? '#94a3b8' : '#f8fafc';
  return shell({
    id,
    bg: '#080c15',
    glow: off ? '#1e293b' : orb.colors.mid,
    glowOpacity: off ? 0.15 : (status === 'WAITING' ? 0.45 : 0.28),
    border,
    borderWidth: selected ? 2.6 : 1.6,
    dim: tile.enabled === false,
    defs: orb.defs,
    body: `${text(tile.agent || tile.label || 'AGENT', 50, 14, 8, agentFill, 800)}
      ${text(tile.workspace || tile.sublabel || '', 50, 28, 12, nameFill, 800)}
      ${orb.body}
      ${pill(tile.detail || status, off ? '#64748b' : '#cbd5e1')}`,
  });
}

function renderAction(tile, frame) {
  const style = ACTIONS[tile.action] || ACTIONS.focus;
  const id = gid(tile.key);
  const waiting = tile.action === 'approve' && tile.status === 'WAITING' && tile.enabled !== false;
  const ring = waiting
    ? `<circle cx="50" cy="48" r="${20 + frame * 2}" fill="none" stroke="${style.accent}" stroke-width="2" stroke-opacity="${(0.85 - frame * 0.18).toFixed(2)}"/>`
    : '';
  return shell({
    id,
    bg: style.bg,
    glow: style.accent,
    glowOpacity: tile.enabled === false ? 0.08 : 0.4,
    border: tile.enabled === false ? '#334155' : style.border,
    borderWidth: waiting ? 2.6 : 1.6,
    dim: tile.enabled === false,
    body: `${text(tile.label, 50, 16, 11, style.title, 800)}
      ${ring}
      ${icon(style.icon, 38, 36)}
      ${pill(tile.detail || tile.sublabel || '', style.caption)}`,
  });
}

function renderTool(tile) {
  const id = gid(tile.key);
  return shell({
    id,
    bg: '#080c15',
    glow: '#6366f1',
    glowOpacity: 0.35,
    border: '#4f46e5',
    borderWidth: 1.6,
    dim: false,
    body: `${text('TOOL', 50, 16, 10, '#a5b4fc', 800)}
      ${icon('tool', 38, 34)}
      ${pill(tile.detail || tile.sublabel || 'idle', '#c7d2fe')}`,
  });
}

function renderRepo(tile) {
  const id = gid(tile.key);
  return shell({
    id,
    bg: '#080c15',
    glow: '#059669',
    glowOpacity: 0.32,
    border: '#059669',
    borderWidth: 1.6,
    dim: false,
    body: `${text('WORKSPACE', 50, 16, 9, '#6ee7b7', 800)}
      ${icon('folder', 38, 34)}
      ${pill(tile.detail || tile.sublabel || 'main', '#a7f3d0')}`,
  });
}

function renderSummary(tile, frame) {
  const id = gid(tile.key);
  const waiting = tile.status === 'WAITING';
  const border = waiting ? '#fbbf24' : '#6366f1';
  const count = Number.isFinite(tile.count) ? tile.count : 0;
  const ring = waiting
    ? `<circle cx="50" cy="50" r="${24 + frame * 1.5}" fill="none" stroke="#fbbf24" stroke-width="2" stroke-opacity="${(0.8 - frame * 0.16).toFixed(2)}"/>`
    : '';
  return shell({
    id,
    bg: '#080c15',
    glow: waiting ? '#f59e0b' : '#6366f1',
    glowOpacity: 0.35,
    border,
    borderWidth: waiting ? 2.6 : 1.6,
    dim: false,
    body: `${text('AGENTS', 50, 16, 10, waiting ? '#fde68a' : '#c7d2fe', 800)}
      ${ring}
      <text x="50" y="58" text-anchor="middle" fill="#f8fafc" font-size="32" font-family="${FONT}" font-weight="800">${count}</text>
      ${pill(tile.detail || '', waiting ? '#fde68a' : '#c7d2fe')}`,
  });
}

function renderGrid(tile) {
  const id = gid(tile.key);
  return shell({
    id,
    bg: '#080c15',
    glow: '#64748b',
    glowOpacity: 0.28,
    border: '#64748b',
    borderWidth: 1.6,
    dim: false,
    body: `${text('GRID', 50, 16, 11, '#e2e8f0', 800)}
      ${icon('grid', 38, 34)}
      ${pill(tile.detail || 'All agents', '#cbd5e1')}`,
  });
}

export function renderTile(tile = {}, frame = 0) {
  const step = ((Number(frame) % 4) + 4) % 4;
  switch (tile.type) {
    case 'action': return renderAction(tile, step);
    case 'tool': return renderTool(tile);
    case 'repo': return renderRepo(tile);
    case 'summary': return renderSummary(tile, step);
    case 'grid': return renderGrid(tile);
    default: return renderInstance(tile, step);
  }
}
