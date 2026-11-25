#!/usr/bin/env node
// bionic-remote bridge: exposes Bionic's on-disk session stores over a small
// token-authenticated HTTP API, so remote clients (e.g. the Sailfish app)
// can watch agent progress and transcripts. Read-only.
//
// Zero dependencies. Node >= 22 (uses node:sqlite).
//
// Config via environment:
//   BRIDGE_PORT        (default 8443)
//   BRIDGE_TOKEN_FILE  (default ~/.config/bionic-remote/token)
//   BRIDGE_TOKEN       (inline token; overrides the file)
//   BIONIC_HOME        (default ~/.lmstudio)
//   BRIDGE_BIND        listen address (default 0.0.0.0; set to the Tailscale
//                      interface IP, e.g. 100.x.y.z, to serve only on the
//                      encrypted tailnet)
//   BRIDGE_ALLOWED_CIDRS  comma-separated allowlist, e.g.
//                      "loopback,tailscale-v6,100.64.0.0/10". Special tokens:
//                      loopback (always allowed), tailscale-v6 (fd7a::/8).
//                      When UNSET, the permissive default applies (loopback +
//                      100.64/10 + fd7a::/8 + 10/8 + 172.16/12 + 192.168/16).

import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const PORT = Number(process.env.BRIDGE_PORT || 8443);
const BIND_ADDR = process.env.BRIDGE_BIND || '0.0.0.0';
const BIONIC_HOME = process.env.BIONIC_HOME || path.join(os.homedir(), '.lmstudio');
const BIONIC_APP = path.join(BIONIC_HOME, 'apps', 'bionic');
const REGISTRY = path.join(BIONIC_APP, '.internal', 'projects-registry.json');
const DEFAULT_STORE = path.join(BIONIC_APP, '.internal', 'ng-sessions.sqlite');
const TOKEN_FILE = process.env.BRIDGE_TOKEN_FILE || path.join(os.homedir(), '.config', 'bionic-remote', 'token');
const VERSION = '0.1.0';

const TEXT_LIMIT = 6000;
const WALK_LIMIT = 5000;
const SUMMARY_LIMIT = 32000;   // compaction summaries can be long docs; allow more
const SUB_WALK_LIMIT = 600;   // entries to walk inside a compaction sub-session
const ACTIVE_WINDOW_MS = 20000;

function log(...a) { console.log(new Date().toISOString(), ...a); }

// ---------- auth / network guards ----------

function loadToken() {
  if (process.env.BRIDGE_TOKEN) return process.env.BRIDGE_TOKEN;
  try {
    return fs.readFileSync(TOKEN_FILE, 'utf8').trim();
  } catch {
    return null;
  }
}

function tokenValid(provided) {
  const expected = loadToken();
  if (!expected || !provided) return false;
  const a = Buffer.from(String(provided));
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// Optional operator allowlist (see BRIDGE_ALLOWED_CIDRS above). Loopback is
// always allowed. When the env var is unset, the permissive default below
// applies so existing setups keep working.
let STRICT_ALLOWED = null;
if (process.env.BRIDGE_ALLOWED_CIDRS) {
  const cidrs = [];
  let tailscaleV6 = false;
  for (const raw of process.env.BRIDGE_ALLOWED_CIDRS.split(',')) {
    const e = raw.trim();
    if (!e || e.toLowerCase() === 'loopback') continue;
    if (e.toLowerCase() === 'tailscale-v6') { tailscaleV6 = true; continue; }
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/.exec(e);
    if (m) cidrs.push([Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5])]);
    else log('WARN: ignoring unknown BRIDGE_ALLOWED_CIDRS entry:', e);
  }
  STRICT_ALLOWED = { cidrs, tailscaleV6 };
  log('allowlist (strict):', JSON.stringify(STRICT_ALLOWED));
}

function ipAllowed(remote) {
  let ip = (remote || '').replace(/^::ffff:/, '');
  if (ip === '127.0.0.1' || ip === '::1') return true;
  if (STRICT_ALLOWED) {
    if (STRICT_ALLOWED.tailscaleV6 && /^fd7a:/i.test(ip)) return true;
    const m = ip.split('.').map(Number);
    if (m.length !== 4 || m.some((n) => Number.isNaN(n))) return false;
    const num = (m[0] << 24 | m[1] << 16 | m[2] << 8 | m[3]) >>> 0;
    return STRICT_ALLOWED.cidrs.some(([a, b, c, d, mask]) => {
      const base = (a << 24 | b << 16 | c << 8 | d) >>> 0;
      const shift = 32 - mask;
      return (num >>> shift) === (base >>> shift);
    });
  }
  // Default (permissive, pre-existing behaviour):
  // Tailscale IPv6 (fd7a::/8) + common private ranges + Tailscale CGNAT.
  if (/^fd7a:/i.test(ip)) return true;
  const m = ip.split('.').map(Number);
  if (m.length !== 4 || m.some((n) => Number.isNaN(n))) return false;
  const inCidr = (base, mask) => {
    const b = base.split('.').map(Number);
    const shift = 32 - mask;
    return ((m[0] << 24 | m[1] << 16 | m[2] << 8 | m[3]) >>> shift) ===
           ((b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) >>> shift);
  };
  return inCidr('100.64.0.0', 10) ||   // Tailscale CGNAT
         inCidr('10.0.0.0', 8) ||
         inCidr('172.16.0.0', 12) ||
         inCidr('192.168.0.0', 16);
}

// ---------- bionic data access ----------

function loadProjects() {
  const raw = JSON.parse(fs.readFileSync(REGISTRY, 'utf8'));
  const projects = [];
  for (const [id, info] of raw?.json?.projects || []) {
    const projDir = path.join(BIONIC_APP, 'projects', id);
    let name = id;
    try {
      name = JSON.parse(fs.readFileSync(path.join(projDir, 'project.json'), 'utf8')).name || id;
    } catch { /* keep id */ }
    let dbPath = path.join(projDir, '.internal', 'ng-sessions.sqlite');
    if (!fs.existsSync(dbPath) && id === 'default-project-identifier') dbPath = DEFAULT_STORE;
    if (!fs.existsSync(dbPath)) dbPath = null;
    projects.push({ id, name, path: info?.projectWorkingDirectoryPath || projDir, dbPath });
  }
  if (!projects.some((p) => p.id === 'general')) {
    projects.unshift({ id: 'general', name: 'General', path: BIONIC_APP, dbPath: fs.existsSync(DEFAULT_STORE) ? DEFAULT_STORE : null });
  }
  return projects;
}

function openDb(dbPath) {
  return new DatabaseSync(dbPath, { readOnly: true });
}

function listSessions(db) {
  const rows = db.prepare(`
    SELECT session_id, session_name, suggested_session_name, has_unread,
           committed_head_entry_id, updated_timestamp
    FROM sessions
    WHERE is_transient = 0 AND is_temporary = 0
    ORDER BY updated_timestamp DESC
  `).all();
  return rows.map((r) => {
    let pending = false, tailKind = null, lastEntryTs = 0;
    try {
      const { entries, pendingApproval, lastEntryTs: ts } = transcript(db, r.committed_head_entry_id, 50);
      pending = !!pendingApproval;
      tailKind = entries.length ? entries[entries.length - 1].kind : null;
      lastEntryTs = ts || 0;
    } catch { /* unreadable store */ }
    const fresh = Math.max(Number(r.updated_timestamp) || 0, lastEntryTs);
    return {
      id: r.session_id,
      name: r.session_name || r.suggested_session_name || 'Untitled session',
      updatedAt: fresh,
      hasUnread: !!r.has_unread,
      active: isActive(fresh, pending, tailKind),
      pendingApproval: pending,
      tailKind,
    };
  });
}

function renderLoc(lm) {
  const parts = lm?.descriptor?.defaultMessage;
  if (!Array.isArray(parts)) return '';
  return parts.map((p) => (p?.type === 1 ? `[${p.value}]` : (p?.value ?? ''))).join('');
}

function flattenPartValues(pv) {
  const out = {};
  for (const [k, v] of Object.entries(pv || {})) {
    if (v && typeof v === 'object' && v.text) out[k] = v.text;
    else if (v && typeof v === 'object') out[k] = JSON.stringify(v);
    else out[k] = String(v);
  }
  return out;
}

function trunc(s) {
  s = String(s ?? '');
  return s.length > TEXT_LIMIT ? s.slice(0, TEXT_LIMIT) + ' …' : s;
}

function truncSummary(s) {
  s = String(s ?? '');
  return s.length > SUMMARY_LIMIT ? s.slice(0, SUMMARY_LIMIT) + ' …' : s;
}

// ---------- markdown → Qt RichText HTML ----------
// Qt 5.6 / QuickText RichText is a subset of HTML; we stick to tags its
// default stylesheet understands (b, i, s, tt, ul/ol/li, blockquote, a).
// The body default stylesheet applies white-space: pre-wrap, so source
// line breaks are preserved. Fenced code uses <tt> (monospace + wrapping)
// instead of <pre> because <pre> lines do not wrap and would overflow
// narrow mobile bubbles. Degraded gracefully on truncated/unclosed
// markers (text is truncated upstream before conversion).

function htmlEsc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function inlineMd(s) {
  // s is already HTML-escaped.
  // 1) Protect inline code spans from the other transforms.
  const codes = [];
  s = s.replace(/`([^`\n]+)`/g, (m, c) => {
    codes.push('<tt>' + c + '</tt>');
    return '\u0001' + (codes.length - 1) + '\u0002';
  });
  // 2) Bold, 3) italic, 4) strikethrough.
  s = s.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
  s = s.replace(/__([^_]+)__/g, '<b>$1</b>');
  s = s.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<i>$2</i>');
  s = s.replace(/~~([^~]+)~~/g, '<s>$1</s>');
  // 5) Links (http/https only).
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2">$1</a>');
  // 6) Restore code spans.
  s = s.replace(/\u0001(\d+)\u0002/g, (m, i) => codes[Number(i)]);
  return s;
}

function blockMd(s) {
  // s is RAW text. Lines are classified first (on unescaped text, so a
  // leading ">" blockquote marker still matches), then each line's content
  // is escaped + inlined. Chunks are joined with newlines so source line
  // breaks survive (Qt's body pre-wrap renders them).
  const lines = s.split('\n');
  const chunks = [];
  let curList = null;
  const flushList = () => {
    if (curList) {
      chunks.push('<' + curList.type + '>' + curList.items.map((i) => '<li>' + i + '</li>').join('') + '</' + curList.type + '>');
      curList = null;
    }
  };
  for (const line of lines) {
    const ul = /^\s*[-*+]\s+(.*)$/.exec(line);
    const ol = /^\s*\d+[.)]\s+(.*)$/.exec(line);
    const hd = /^(#{1,6})\s+(.*)$/.exec(line);
    const bq = /^\s*>\s?(.*)$/.exec(line);
    if (ul) {
      if (!curList || curList.type !== 'ul') { flushList(); curList = { type: 'ul', items: [] }; }
      curList.items.push(inlineMd(htmlEsc(ul[1])));
      continue;
    }
    if (ol) {
      if (!curList || curList.type !== 'ol') { flushList(); curList = { type: 'ol', items: [] }; }
      curList.items.push(inlineMd(htmlEsc(ol[1])));
      continue;
    }
    flushList();
    if (hd) chunks.push('<b>' + inlineMd(htmlEsc(hd[2])) + '</b>');
    else if (bq) chunks.push('<blockquote>' + inlineMd(htmlEsc(bq[1])) + '</blockquote>');
    else chunks.push(line.trim() === '' ? '' : inlineMd(htmlEsc(line)));
  }
  flushList();
  return chunks.join('\n');
}

function mdToHtml(md) {
  md = String(md ?? '');
  // Split off fenced code blocks first.
  const segments = [];
  let rest = md;
  const fenceRe = /^(```|~~~)/m;
  while (fenceRe.test(rest)) {
    const m = rest.match(fenceRe);
    const fence = m[1];
    const close = rest.indexOf('\n' + fence, m.index + fence.length);
    if (close === -1) { segments.push({ text: rest, code: false }); rest = ''; break; }
    segments.push({ text: rest.slice(0, m.index), code: false });
    let inner = rest.slice(m.index + fence.length, close);
    inner = inner.replace(/^\n/, '').replace(/\n$/, '');
    segments.push({ text: inner, code: true });
    rest = rest.slice(close + 1 + fence.length);
  }
  if (rest) segments.push({ text: rest, code: false });
  let html = '';
  for (const seg of segments) {
    if (seg.code) html += '<tt>' + htmlEsc(seg.text) + '</tt>\n';
    else html += blockMd(seg.text);
  }
  return html;
}

// Walk the entry chain backwards from the head, newest first.
function walkEntries(db, headId, cap = WALK_LIMIT) {
  const byId = new Map();
  const get = (id) => {
    if (byId.has(id)) return byId.get(id);
    let row = null;
    try {
      row = db.prepare('SELECT entry_json FROM chat_entries WHERE id = ?').get(id);
    } catch { row = null; }
    let entry = null;
    if (row) {
      try { entry = JSON.parse(row.entry_json); } catch { entry = null; }
    }
    byId.set(id, entry);
    return entry;
  };

  const chain = [];
  const seen = new Set();
  let cur = headId;
  while (cur && chain.length < cap && !seen.has(cur)) {
    seen.add(cur);
    let entry = get(cur);
    if (!entry) break;
    if (entry.type === 'redirect' && entry.redirect_to_id) {
      const target = get(entry.redirect_to_id);
      if (target) { chain.push(target); cur = target.previousId; continue; }
    }
    chain.push(entry);
    cur = entry.previousId;
  }
  return chain;
}

function normalizeEntry(entry, answeredRequests, db = null, ctx = null) {
  const t = entry?.type;
  if (t === 'message') {
    if (entry.hidden) return null;
    const msg = entry.message || {};
    const role = msg.role;
    const parts = Array.isArray(msg.parts) ? msg.parts : [];
    const out = [];
    const pushText = (text, kind) => {
      if (!text) return;
      const s = trunc(text);
      const o = { kind, text: s };
      // Rich (markdown) rendering only for chat bubbles, and only when the
      // caller asked for rich output (light paths like session listing skip
      // it to stay cheap).
      if (ctx?.rich && (kind === 'user' || kind === 'assistant')) o.html = mdToHtml(s);
      out.push(o);
    };

    // User messages: one bubble from all text parts (+ image placeholders).
    if (role === 'user') {
      const texts = parts.filter((p) => p && p.type === 'text' && p.text)
                         .map((p) => String(p.text));
      const imgs = parts.filter((p) => p && p.type === 'image').length;
      if (imgs > 0) texts.push('[' + imgs + ' image' + (imgs > 1 ? 's' : '') + ']');
      pushText(texts.join('\n'), 'user');
      return out.length > 0 ? out : null;
    }

    // Assistant / tool messages: emit parts in order. Real part types are
    // 'reasoning' (thinking), 'text', 'toolCallRequest', 'toolCallResult'.
    for (const p of parts) {
      if (!p) continue;
      if (p.type === 'reasoning' && p.text) {
        pushText(String(p.text), 'reasoning');
      }
      else if (p.type === 'text' && p.text) {
        pushText(String(p.text), role === 'assistant' ? 'assistant' : 'system');
      }
      else if (p.type === 'toolCallRequest' || p.type === 'toolCall') {
        const argsRaw = p.parameters ?? p.args ?? p.arguments ?? p.input ?? {};
        out.push({
          kind: 'tool_call',
          tool: p.name || p.toolName || 'tool',
          args: trunc(JSON.stringify(argsRaw, null, 2)),
        });
      }
      else if (p.type === 'toolCallResult') {
        const r = (p.result || [])
          .map((x) => (x && x.type === 'text' ? x.text : JSON.stringify(x)))
          .join('\n');
        pushText(r, role === 'tool' ? 'tool_result' : 'system');
      }
    }
    return out.length > 0 ? out : null;
  }
  if (t === 'elicitationRequest') {
    const choices = (entry.steps || []).flatMap((s) => (s?.choices || []).map((c) => ({ value: c.value, label: renderLoc(c.label) || String(c.value) })));
    return {
      kind: 'approval',
      title: renderLoc(entry.title) || (entry.source?.toolId || 'Approval request'),
      description: renderLoc(entry.description),
      details: flattenPartValues(entry.partValues),
      tool: entry.source?.toolId || null,
      choices,
      requestId: entry.requestId || null,
      answered: !!answeredRequests.has(entry.requestId),
    };
  }
  if (t === 'stateChange') {
    const sc = (entry.stateChanges || [])[0];
    if (sc?.previewText) return { kind: 'system', text: String(sc.previewText) };
    return null;
  }
  if (t === 'turnSummary') return { kind: 'system', text: '— earlier conversation was summarized —', turnSummary: true };
  if (t === 'interrupted') return { kind: 'system', text: 'Interrupted' };
  if (t === 'subSessionReference') return compactionCard(db, entry, ctx);
  return null; // forkPoint, resourceHold, ...
}

// A compaction marker is a subSessionReference into a transient "Compaction"
// sub-session (source.ngModule = lmstudio/context-compaction-v1).
// The card shows the compaction summary (newest assistant text in the
// sub-session) expandable, plus a "worked for" duration taken from a
// turnSummary entry in the sub-chain (fallback: the next main-chain entry).
function compactionCard(db, entry, ctx) {
  const ng = String(entry?.source?.ngModule || '');
  const isCompaction = /context-compaction/i.test(ng)
    || /compacted/i.test(String(entry?.doneTitle || ''));
  if (!isCompaction || !db || !ctx?.rich) return null;
  const card = { kind: 'compacted', title: entry.doneTitle || 'Compacted', workedForMs: null, files: 0, summary: '' };
  try {
    const sub = db.prepare('SELECT committed_head_entry_id FROM sessions WHERE session_id = ?').get(entry.sessionId);
    if (sub?.committed_head_entry_id) {
      const sc = walkEntries(db, sub.committed_head_entry_id, SUB_WALK_LIMIT);
      for (const e of sc) {
        if (e?.type === 'message' && e.message?.role === 'assistant') {
          const txt = (e.message.parts || [])
            .filter((p) => p?.type === 'text' && p.text)
            .map((p) => String(p.text)).join('\n');
          if (txt) { card.summary = truncSummary(txt); break; }
        }
      }
      const ts = sc.find((e) => e?.type === 'turnSummary');
      if (ts) {
        if (Number(ts.durationMs) > 0) card.workedForMs = Math.round(ts.durationMs);
        card.files = Array.isArray(ts.files) ? ts.files.length : 0;
      }
    }
  } catch { /* keep whatever we managed to collect */ }
  if (card.workedForMs == null && ctx.next?.type === 'turnSummary') {
    if (Number(ctx.next.durationMs) > 0) card.workedForMs = Math.round(ctx.next.durationMs);
    if (card.files === 0 && Array.isArray(ctx.next.files)) card.files = ctx.next.files.length;
  }
  if (card.summary) card.summaryHtml = mdToHtml(card.summary);
  return card;
}

function transcript(db, headId, limit = 100, opts = {}) {
  const chain = walkEntries(db, headId);
  let lastEntryTs = 0;
  for (const e of chain) {
    const ts = Number(e?.createdTimestamp) || 0;
    if (ts > lastEntryTs) lastEntryTs = ts;
  }
  const answered = new Set();
  for (const e of chain) if (e?.type === 'elicitationResponse' && e.requestId) answered.add(e.requestId);
  const out = [];
  for (let i = 0; i < chain.length; i++) {
    const ctx = { next: chain[i + 1] || null, rich: !!opts.rich };
    const ns = normalizeEntry(chain[i], answered, db, ctx);
    if (!ns) continue;
    if (Array.isArray(ns)) { for (const n of ns) out.push(n); }
    else out.push(ns);
  }
  out.reverse(); // oldest → newest
  // When a compaction card is present it already carries the duration, so the
  // bare "summarized" system line would just duplicate it — drop those.
  if (opts.rich && out.some((n) => n.kind === 'compacted')) {
    for (let i = out.length - 1; i >= 0; i--) if (out[i] && out[i].turnSummary) out.splice(i, 1);
  }
  // Newest-`limit` window, extended back to include the most recent
  // compaction card if it falls outside it (long sessions push it back).
  // The card carries the summary the user came to read, so it must stay in
  // the response even when the live tail alone would exclude it.
  let start = Math.max(0, out.length - Math.max(1, limit));
  for (let i = start - 1; i >= 0; i--) {
    if (out[i] && out[i].kind === 'compacted') { start = i; break; }
  }
  const entries = out.slice(start);
  let pending = null;
  for (let i = out.length - 1; i >= 0; i--) {
    const n = out[i];
    if (n.kind === 'approval') { pending = n.answered ? null : n; break; }
  }
  return { entries, pendingApproval: pending, lastEntryTs };
}

const STALE_WINDOW_MS = 15 * 60 * 1000;

// A finished turn always ends with a plain assistant text message; anything
// else at the tail means the turn is still in flight (model or tool pending).
function isActive(updatedTs, pending, tailKind) {
  const age = Date.now() - Number(updatedTs);
  if (age < ACTIVE_WINDOW_MS) return true;
  if (pending) return true;
  if (tailKind && tailKind !== 'assistant' && age < STALE_WINDOW_MS) return true;
  return false;
}

function sessionDetail(db, sid) {
  let row = null;
  try { row = db.prepare('SELECT * FROM sessions WHERE session_id = ?').get(sid); } catch { row = null; }
  if (!row) return null;
  const { entries, pendingApproval, lastEntryTs } = transcript(db, row.committed_head_entry_id, 50);
  const tailKind = entries.length ? entries[entries.length - 1].kind : null;
  const fresh = Math.max(Number(row.updated_timestamp) || 0, lastEntryTs || 0);
  return {
    id: row.session_id,
    name: row.session_name || row.suggested_session_name || 'Untitled session',
    updatedAt: fresh,
    hasUnread: !!row.has_unread,
    active: isActive(fresh, !!pendingApproval, tailKind),
    pendingApproval,
    lastActivity: tailKind,
    headEntryId: row.committed_head_entry_id,
  };
}

// ---------- http ----------

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const remote = req.socket.remoteAddress || '';
  console.log(new Date().toISOString(), "REQ", remote, req.method, req.url,
    "auth=" + (req.headers['authorization'] ? 'yes' : 'no'),
    "authlen=" + ((req.headers['authorization']||'').length));
  if (!ipAllowed(remote)) return sendJson(res, 403, { error: 'source address not allowed' });
  const url = new URL(req.url, 'http://localhost');
  const auth = (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '');
  if (url.pathname !== '/v1/health' && !tokenValid(auth)) {
    return sendJson(res, 401, { error: 'unauthorized' });
  }

  const p = url.pathname;
  try {
    if (req.method === 'GET' && p === '/v1/health') {
      const projects = loadProjects().filter((x) => x.dbPath);
      return sendJson(res, 200, { ok: true, name: 'bionic-remote-bridge', version: VERSION, projects: projects.length, time: Date.now() });
    }

    if (req.method === 'GET' && p === '/v1/projects') {
      const now = Date.now();
      const projects = loadProjects().map((pr) => {
        let sessionCount = 0, lastActivity = 0, active = false;
        if (pr.dbPath) {
          try {
            const db = openDb(pr.dbPath);
            const rows = listSessions(db);
            sessionCount = rows.length;
            for (const s of rows) {
              if (s.updatedAt > lastActivity) lastActivity = s.updatedAt;
              if (s.active) active = true;
            }
            db.close();
          } catch { /* store unavailable */ }
        }
        return {
          id: pr.id, name: pr.name, path: pr.path,
          sessionCount,
          lastActivity: now - lastActivity < 365e10 ? lastActivity : null,
          active,
        };
      }).filter((pr) => pr.dbPath || pr.sessionCount > 0);
      return sendJson(res, 200, { projects });
    }

    const mSess = p.match(/^\/v1\/projects\/([^/]+)\/sessions$/);
    if (req.method === 'GET' && mSess) {
      const pr = loadProjects().find((x) => x.id === decodeURIComponent(mSess[1]));
      if (!pr) return sendJson(res, 404, { error: 'unknown project' });
      if (!pr.dbPath) return sendJson(res, 503, { error: 'session store not found' });
      const db = openDb(pr.dbPath);
      try {
        const sessions = listSessions(db);
        return sendJson(res, 200, { project: { id: pr.id, name: pr.name, path: pr.path }, sessions });
      } finally { db.close(); }
    }

    const mTrans = p.match(/^\/v1\/projects\/([^/]+)\/sessions\/([^/]+)\/transcript$/);
    if (req.method === 'GET' && mTrans) {
      const pr = loadProjects().find((x) => x.id === decodeURIComponent(mTrans[1]));
      if (!pr) return sendJson(res, 404, { error: 'unknown project' });
      if (!pr.dbPath) return sendJson(res, 503, { error: 'session store not found' });
      const limit = Math.min(500, Math.max(1, Number(url.searchParams.get('limit') || 100)));
      const db = openDb(pr.dbPath);
      try {
        const detail = sessionDetail(db, decodeURIComponent(mTrans[2]));
        if (!detail) return sendJson(res, 404, { error: 'unknown session' });
        const { entries, pendingApproval } = transcript(db, detail.headEntryId, limit, { rich: true });
        return sendJson(res, 200, {
          session: { id: detail.id, name: detail.name, updatedAt: detail.updatedAt, active: detail.active },
          pendingApproval,
          entries,
        });
      } finally { db.close(); }
    }

    const mDet = p.match(/^\/v1\/projects\/([^/]+)\/sessions\/([^/]+)$/);
    if (req.method === 'GET' && mDet) {
      const pr = loadProjects().find((x) => x.id === decodeURIComponent(mDet[1]));
      if (!pr) return sendJson(res, 404, { error: 'unknown project' });
      if (!pr.dbPath) return sendJson(res, 503, { error: 'session store not found' });
      const db = openDb(pr.dbPath);
      try {
        const detail = sessionDetail(db, decodeURIComponent(mDet[2]));
        if (!detail) return sendJson(res, 404, { error: 'unknown session' });
        return sendJson(res, 200, detail);
      } finally { db.close(); }
    }

    return sendJson(res, 404, { error: 'not found' });
  } catch (err) {
    log('ERROR', req.method, p, String(err?.stack || err));
    return sendJson(res, 500, { error: 'internal error' });
  }
});

server.listen(PORT, BIND_ADDR, () => {
  log(`bionic-remote-bridge v${VERSION} listening on ${BIND_ADDR}:${PORT} (bionic home: ${BIONIC_HOME})`);
});
