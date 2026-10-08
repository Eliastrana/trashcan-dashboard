// Status page for the trashcan. Zero dependencies, binds to localhost; Caddy puts TLS in front.
// Everything except the login page and its static assets needs a signed session cookie.
// Set the password with `node set-password.js`; until then the page stays locked.
import http from 'node:http';
import net from 'node:net';
import tls from 'node:tls';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 3020;
const HOST = process.env.HOST || '127.0.0.1';
const DATA = process.env.DATA_DIR || path.join(HERE, 'data');
const PASS_FILE = path.join(DATA, 'password.json');
const HISTORY_FILE = path.join(DATA, 'history.json');
const INTERVAL_MS = 60_000;
const KEEP = 1440;                 // one sample per minute for 24 hours
const SESSION_MS = 12 * 3600_000;
const SLOW_MS = 1500;
fs.mkdirSync(DATA, { recursive: true, mode: 0o700 });

// ---------------------------------------------------------------- what to check
const local = (port, p = '/') => ({ kind: 'http', url: `http://127.0.0.1:${port}${p}` });
const SERVICES = [
  { id: 'caddy', icon: 'caddy',     name: 'Caddy (reverse proxy)',     group: 'Edge',     kind: 'tcp', port: 8443, link: '127.0.0.1:8443 (443 utenfra)' },
  { id: 'arcade', icon: 'arcade',    name: 'arcade.eliastrana.no',      group: 'Websites', kind: 'public', host: 'arcade.eliastrana.no', link: 'https://arcade.eliastrana.no' },
  { id: 'hitster', icon: 'hitster',   name: 'hitster.eliastrana.no',     group: 'Websites', kind: 'public', host: 'hitster.eliastrana.no', link: 'https://hitster.eliastrana.no' },
  { id: 'map', icon: 'minecraft',       name: 'minecraftmap.eliastrana.no', group: 'Websites', kind: 'public', host: 'minecraftmap.eliastrana.no', link: 'https://minecraftmap.eliastrana.no' },
  { id: 'llm', icon: 'ollama',       name: 'llm.eliastrana.no',         group: 'Websites', kind: 'public', host: 'llm.eliastrana.no', link: 'https://llm.eliastrana.no' },
  { id: 'arena', icon: 'arcade',     name: 'Arena server',              group: 'Backends', ...local(3001), link: '127.0.0.1:3001' },
  { id: 'hitweb', icon: 'hitster',    name: 'Ikke-Hitster web',          group: 'Backends', ...local(3010), link: '127.0.0.1:3010' },
  { id: 'hitws', icon: 'hitster',     name: 'Ikke-Hitster game server',  group: 'Backends', ...local(3002, '/health'), link: '127.0.0.1:3002' },
  { id: 'mcpack', icon: 'minecraft',    name: 'Minecraft resource packs',  group: 'Backends', ...local(8090), link: 'http://eliastrana.tplinkdns.com:8090' },
  { id: 'chatbot', icon: 'ollama',   name: 'Chat (llm.eliastrana.no)',  group: 'Backends', ...local(3030), link: '127.0.0.1:3030' },
  { id: 'llmgate', icon: 'lock',   name: 'Login for llm.eliastrana.no', group: 'Backends', ...local(3040, '/login'), link: '127.0.0.1:3040' },
  { id: 'bluemap', icon: 'minecraft',   name: 'BlueMap',                   group: 'Backends', ...local(8100), link: '127.0.0.1:8100' },
  { id: 'minecraft', icon: 'minecraft', name: 'Minecraft server',          group: 'Games',    kind: 'tcp', port: 25565, link: 'eliastrana.tplinkdns.com:25565' },
  { id: 'ssh', icon: 'ssh',       name: 'SSH portfolio',             group: 'Other',    kind: 'banner', port: 2222, expect: 'SSH-', link: 'ssh portfolio.eliastrana.no' },
  { id: 'plex', icon: 'plex',      name: 'Plex',                      group: 'Other',    ...local(32400, '/identity'), link: 'http://192.168.0.138:32400/web' },
  { id: 'ollama', icon: 'ollama',    name: 'Ollama',                    group: 'Other',    ...local(11434), link: 'https://llm.eliastrana.no/ollama/ (api)' },
];

const now = () => Date.now();
const timed = async (fn) => { const t = performance.now(); try { const detail = await fn(); return { ok: true, ms: Math.round(performance.now() - t), detail }; } catch (e) { return { ok: false, ms: Math.round(performance.now() - t), detail: String(e.message || e) }; } };

const tcp = (port, { banner } = {}) => new Promise((resolve, reject) => {
  const s = net.connect({ host: '127.0.0.1', port, timeout: 4000 });
  s.once('connect', () => { if (!banner) { s.destroy(); resolve('open'); } });
  s.once('data', (d) => { s.destroy(); const text = d.toString('latin1', 0, 60); text.startsWith(banner) ? resolve(text.trim()) : reject(new Error('unexpected banner')); });
  s.once('timeout', () => { s.destroy(); reject(new Error('timeout')); });
  s.once('error', reject);
});

const httpGet = (url) => new Promise((resolve, reject) => {
  const req = http.get(url, { timeout: 5000 }, (res) => { res.resume(); res.statusCode < 500 ? resolve(`HTTP ${res.statusCode}`) : reject(new Error(`HTTP ${res.statusCode}`)); });
  req.once('timeout', () => req.destroy(new Error('timeout')));
  req.once('error', reject);
});

/** Ask Caddy for a site the way the internet does (SNI + Host), and read the certificate expiry. */
const publicSite = (host) => new Promise((resolve, reject) => {
  const sock = tls.connect({ host: '127.0.0.1', port: 8443, servername: host, rejectUnauthorized: false, timeout: 5000 }, () => {
    const cert = sock.getPeerCertificate();
    const days = cert?.valid_to ? Math.floor((new Date(cert.valid_to) - now()) / 86_400_000) : null;
    sock.write(`GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`);
    sock.once('data', (d) => {
      const code = Number(d.toString('latin1', 9, 12));
      sock.destroy();
      if (!(code < 500)) return reject(new Error(`HTTP ${code || '?'}`));
      resolve({ text: `HTTP ${code}`, certDays: days });
    });
  });
  sock.once('timeout', () => { sock.destroy(); reject(new Error('timeout')); });
  sock.once('error', reject);
});

async function runCheck(svc) {
  const r = await timed(async () => {
    if (svc.kind === 'tcp') return tcp(svc.port);
    if (svc.kind === 'banner') return tcp(svc.port, { banner: svc.expect });
    if (svc.kind === 'http') return httpGet(svc.url);
    if (svc.kind === 'public') { const p = await publicSite(svc.host); svc.certDays = p.certDays; return p.text; }
  });
  return { ...r, certDays: svc.certDays ?? null };
}

// ---------------------------------------------------------------- machine stats
const sh = (cmd, args) => new Promise((resolve) => execFile(cmd, args, { timeout: 5000 }, (e, out) => resolve(e ? '' : out)));
// CPU use = share of time the cores were busy since the previous reading (so each value is an average over the last
// minute or so). The first reading takes a short sample of its own.
let lastCpu = null;
const cpuTotals = () => os.cpus().reduce((a, c) => {
  const t = c.times;
  a.idle += t.idle; a.total += t.user + t.nice + t.sys + t.idle + t.irq;
  return a;
}, { idle: 0, total: 0 });
async function cpuPercent() {
  let before = lastCpu;
  if (!before) { before = cpuTotals(); await new Promise((r) => setTimeout(r, 500)); }
  const now_ = cpuTotals();
  lastCpu = now_;
  const total = now_.total - before.total;
  if (total <= 0) return null;
  return Math.round((1 - (now_.idle - before.idle) / total) * 100);
}

async function machine() {
  const cores = os.cpus().length;
  const load = os.loadavg();
  let memTotal = os.totalmem(), memUsed = null;
  const vm = await sh('vm_stat', []);
  if (vm) {
    const page = Number(/page size of (\d+)/.exec(vm)?.[1] || 4096);
    const get = (k) => Number(new RegExp(`${k}:\\s+(\\d+)`).exec(vm)?.[1] || 0) * page;
    // macOS keeps "inactive" and "speculative" pages around as cache, so they count as available.
    memUsed = memTotal - get('Pages free') - get('Pages inactive') - get('Pages speculative') - get('Pages purgeable');
  }
  let disk = null;
  const df = (await sh('df', ['-k', '/System/Volumes/Data'])).split('\n')[1]?.trim().split(/\s+/);
  if (df) disk = { totalGB: Math.round(Number(df[1]) / 1048576), freeGB: Math.round(Number(df[3]) / 1048576), usedPct: Math.round((1 - Number(df[3]) / Number(df[1])) * 100) };
  const cpuPct = await cpuPercent();
  return { cores, load, cpuPct, memTotalGB: +(memTotal / 2 ** 30).toFixed(1), memUsedGB: memUsed === null ? null : +(memUsed / 2 ** 30).toFixed(1), disk, uptimeS: Math.round(os.uptime()) };
}

// ---------------------------------------------------------------- sampling + history
let history = {};
try { history = JSON.parse(fs.readFileSync(HISTORY_FILE, 'utf8')); } catch { history = {}; }
let latest = { at: 0, services: {}, machine: null };

async function sample() {
  const at = now();
  const results = await Promise.all(SERVICES.map(async (s) => [s.id, await runCheck(s)]));
  for (const [id, r] of results) {
    (history[id] ||= []).push([at, r.ok ? 1 : 0, r.ms]);
    if (history[id].length > KEEP) history[id].splice(0, history[id].length - KEEP);
  }
  latest = { at, services: Object.fromEntries(results), machine: await machine() };
}
const persist = () => { try { fs.writeFileSync(HISTORY_FILE, JSON.stringify(history), { mode: 0o600 }); } catch { /* disk full or read-only: keep serving */ } };
sample().catch(() => {});
setInterval(() => sample().catch(() => {}), INTERVAL_MS);
setInterval(persist, 5 * 60_000);
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { persist(); process.exit(0); });

function view() {
  const day = now() - 86_400_000;
  return {
    at: latest.at, machine: latest.machine, controlsEnabled: controlsEnabled(),
    services: SERVICES.map((s) => {
      const r = latest.services[s.id];
      const h = (history[s.id] || []).filter(([t]) => t >= day);
      const buckets = Array(48).fill(null);              // 30 minute buckets, oldest first
      for (const [t, ok] of h) {
        const i = Math.min(47, Math.floor((t - day) / 1_800_000));
        buckets[i] = buckets[i] === null ? ok : Math.min(buckets[i], ok);
      }
      const up = h.filter(([, ok]) => ok).length;
      return {
        id: s.id, name: s.name, group: s.group, icon: s.icon || null, url: s.link || null,
        controls: controlsEnabled() && Object.hasOwn(CONTROLS, s.id) ? CONTROLS[s.id] : [],
        busy: busy[s.id]?.action ?? null,
        state: !r ? 'unknown' : !r.ok ? 'down' : r.ms > SLOW_MS ? 'slow' : 'up',
        ms: r?.ms ?? null, detail: r?.detail ?? null, certDays: r?.certDays ?? null,
        uptimePct: h.length ? +((up / h.length) * 100).toFixed(2) : null, buckets,
      };
    }),
  };
}

// ---------------------------------------------------------------- start / stop / restart
// The page itself has no rights. It asks a root-owned helper (/opt/apps/bin/svc-control) through sudo, and sudo only
// allows that helper for the exact id/action pairs in /etc/sudoers.d/status-control. The list below is the same list,
// so a request for anything else is refused here before it gets that far.
const CONTROL_BIN = process.env.CONTROL_BIN || '/opt/apps/bin/svc-control';
const CONTROLS = {
  caddy: ['restart'],                                  // stopping it would also take this page offline
  arena: ['stop', 'start', 'restart'],
  hitweb: ['stop', 'start', 'restart'],
  hitws: ['stop', 'start', 'restart'],
  mcpack: ['stop', 'start', 'restart'],
  minecraft: ['stop', 'start', 'restart'],
};
const CONTROL_LOG = path.join(DATA, 'control.log');
const MAX_ACTIONS_PER_MINUTE = 6;
const busy = {};                                        // id -> { action, since }
let recentActions = [];                                 // timestamps, for the rate limit
const controlsEnabled = () => fs.existsSync(CONTROL_BIN);
const audit = (line) => {
  const text = `${new Date().toISOString()} ${line}`;
  console.log(`[control] ${text}`);
  try { fs.appendFileSync(CONTROL_LOG, text + '\n', { mode: 0o600 }); } catch { /* keep going without a file log */ }
};

function runControl(id, action, ip) {
  busy[id] = { action, since: now() };
  audit(`start id=${id} action=${action} ip=${ip}`);
  const [cmd, args] = process.env.CONTROL_NO_SUDO ? [CONTROL_BIN, [id, action]] : ['/usr/bin/sudo', ['-n', CONTROL_BIN, id, action]];
  execFile(cmd, args, { timeout: 12 * 60_000 }, (err, stdout, stderr) => {
    delete busy[id];
    audit(`done  id=${id} action=${action} ok=${!err} ${err ? `error=${JSON.stringify(String(stderr || err.message).trim().slice(0, 200))}` : `result=${JSON.stringify(String(stdout).trim().slice(0, 100))}`}`);
    sample().catch(() => {});
    setTimeout(() => sample().catch(() => {}), 8000);
  });
}

async function readBody(req, max) {
  let body = '';
  for await (const chunk of req) { body += chunk; if (body.length > max) throw new Error('too large'); }
  return body;
}

async function handleControl(req, res) {
  const json = (code, obj) => send(res, code, JSON.stringify(obj), 'application/json');
  // Only the page itself may call this. A custom header cannot be added by another website without a CORS preflight,
  // which this server never answers; the origin checks are a second lock.
  if (req.headers['x-requested-with'] !== 'status-page') return json(403, { error: 'forbidden' });
  if (req.headers.origin) {
    let ok = false;
    try { ok = new URL(req.headers.origin).host === req.headers.host; } catch { ok = false; }
    if (!ok) return json(403, { error: 'forbidden' });
  }
  if (req.headers['sec-fetch-site'] && !['same-origin', 'none'].includes(req.headers['sec-fetch-site'])) return json(403, { error: 'forbidden' });
  if (!String(req.headers['content-type'] || '').startsWith('application/json')) return json(415, { error: 'json only' });

  let msg;
  try { msg = JSON.parse(await readBody(req, 256)); } catch { return json(400, { error: 'bad request' }); }
  const { id, action } = msg || {};
  if (typeof id !== 'string' || typeof action !== 'string'
    || !Object.hasOwn(CONTROLS, id) || !CONTROLS[id].includes(action)) return json(400, { error: 'not allowed' });
  if (!controlsEnabled()) return json(503, { error: 'Styring er ikke installert på maskinen ennå.' });

  const ip = ipOf(req);
  recentActions = recentActions.filter((t) => t > now() - 60_000);
  if (recentActions.length >= MAX_ACTIONS_PER_MINUTE) { audit(`refused id=${id} action=${action} ip=${ip} reason=rate-limit`); return json(429, { error: 'For mange handlinger. Vent et minutt.' }); }
  if (busy[id]) return json(409, { error: 'Den jobber allerede med noe.' });

  recentActions.push(now());
  runControl(id, action, ip);
  json(202, { ok: true });
}

// ---------------------------------------------------------------- auth
const b64 = (b) => Buffer.from(b).toString('base64url');
const readAuth = () => { try { return JSON.parse(fs.readFileSync(PASS_FILE, 'utf8')); } catch { return null; } };
const sign = (auth, payload) => crypto.createHmac('sha256', Buffer.from(auth.secret, 'base64')).update(payload).digest('base64url');
function makeSession(auth) { const exp = String(now() + SESSION_MS); return `${exp}.${sign(auth, exp)}`; }
function validSession(auth, cookie) {
  if (!auth || !cookie) return false;
  const [exp, mac] = cookie.split('.');
  if (!exp || !mac || Number(exp) < now()) return false;
  const want = Buffer.from(sign(auth, exp)), got = Buffer.from(mac);
  return want.length === got.length && crypto.timingSafeEqual(want, got);
}
function checkPassword(auth, password) {
  const hash = crypto.scryptSync(password, Buffer.from(auth.salt, 'base64'), 64);
  const want = Buffer.from(auth.hash, 'base64');
  return hash.length === want.length && crypto.timingSafeEqual(hash, want);
}
const cookieOf = (req) => Object.fromEntries((req.headers.cookie || '').split(/;\s*/).map((c) => c.split('=').map(decodeURIComponent)).filter((p) => p.length === 2)).st;
const fails = new Map();   // ip -> [timestamps]
const ipOf = (req) => (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress;
const locked = (ip) => { const f = (fails.get(ip) || []).filter((t) => t > now() - 600_000); fails.set(ip, f); return f.length >= 5; };

// ---------------------------------------------------------------- http
const HEADERS = {
  'Content-Security-Policy': "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
  'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store',
  'X-Robots-Tag': 'noindex, nofollow',
};
const send = (res, code, body, type = 'text/html; charset=utf-8', extra = {}) => { res.writeHead(code, { ...HEADERS, 'Content-Type': type, ...extra }); res.end(body); };
const asset = (name) => fs.readFileSync(path.join(HERE, 'public', name), 'utf8');
const loginPage = (msg = '') => asset('login.html').replace('<!--MSG-->', msg);

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const auth = readAuth();
  const secure = req.headers['x-forwarded-proto'] === 'https' ? '; Secure' : '';
  const authed = validSession(auth, cookieOf(req));

  if (req.method === 'GET' && url.pathname === '/favicon.svg') return send(res, 200, asset('favicon.svg'), 'image/svg+xml', { 'Cache-Control': 'public, max-age=86400' });
  if (req.method === 'GET' && url.pathname === '/favicon.ico') return send(res, 302, '', 'text/plain', { Location: '/favicon.svg' });
  if (req.method === 'GET' && authed && /^\/icons\/[a-z]+\.svg$/.test(url.pathname) && fs.existsSync(path.join(HERE, 'public', url.pathname))) return send(res, 200, asset(url.pathname.slice(1)), 'image/svg+xml', { 'Cache-Control': 'private, max-age=86400' });
  if (req.method === 'GET' && url.pathname === '/app.css') return send(res, 200, asset('app.css'), 'text/css; charset=utf-8');
  if (req.method === 'GET' && url.pathname === '/app.js') return authed ? send(res, 200, asset('app.js'), 'text/javascript; charset=utf-8') : send(res, 401, '');

  if (url.pathname === '/login') {
    if (req.method === 'GET') return send(res, 200, loginPage(auth ? '' : '<p class="msg">Passord er ikke satt opp ennå.</p>'));
    if (req.method === 'POST') {
      const ip = ipOf(req);
      if (!auth) return send(res, 503, loginPage('<p class="msg">Passord er ikke satt opp ennå.</p>'));
      if (locked(ip)) return send(res, 429, loginPage('<p class="msg">For mange forsøk. Vent ti minutter.</p>'));
      let body = ''; for await (const c of req) { body += c; if (body.length > 2048) return send(res, 413, ''); }
      const password = new URLSearchParams(body).get('password') || '';
      if (password.length && checkPassword(auth, password)) {
        fails.delete(ip);
        return send(res, 303, '', 'text/plain', { Location: '/', 'Set-Cookie': `st=${encodeURIComponent(makeSession(auth))}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${SESSION_MS / 1000}${secure}` });
      }
      fails.set(ip, [...(fails.get(ip) || []), now()]);
      await new Promise((r) => setTimeout(r, 600));       // slow guessing down a little
      return send(res, 401, loginPage('<p class="msg">Feil passord.</p>'));
    }
  }
  if (req.method === 'POST' && url.pathname === '/logout') return send(res, 303, '', 'text/plain', { Location: '/login', 'Set-Cookie': `st=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure}` });

  if (!authed) return url.pathname === '/' ? send(res, 303, '', 'text/plain', { Location: '/login' }) : send(res, 401, 'unauthorized', 'text/plain');
  if (req.method === 'POST' && url.pathname === '/api/control') return handleControl(req, res);
  if (req.method === 'GET' && url.pathname === '/api/status') return send(res, 200, JSON.stringify(view()), 'application/json');
  if (req.method === 'GET' && url.pathname === '/') return send(res, 200, asset('index.html'));
  send(res, 404, 'not found', 'text/plain');
});
server.listen(PORT, HOST, () => console.log(`status listening on ${HOST}:${PORT} (${readAuth() ? 'password set' : 'LOCKED: run set-password.js'})`));
