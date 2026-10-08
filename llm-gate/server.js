// Login gate for llm.eliastrana.no. Zero dependencies, binds to localhost; Caddy sits in front.
//
// Caddy asks this service about every request (forward_auth -> GET /verify). A request is let through when it carries
// a valid session cookie (set by the login page) or valid HTTP Basic credentials (for scripts and apps talking to /ollama/).
// Anything else is turned away: browsers are sent to the login page, scripts get a plain 401.
//
// Set the password with `node set-password.js`; until then every request is refused.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 3040;
const HOST = process.env.HOST || '127.0.0.1';
const DATA = process.env.DATA_DIR || path.join(HERE, 'data');
const PASS_FILE = path.join(DATA, 'password.json');
const BASIC_USER = process.env.BASIC_USER || 'elias';
const COOKIE = 'llm_session';
const SESSION_MS = 7 * 24 * 3600_000;
fs.mkdirSync(DATA, { recursive: true, mode: 0o700 });

// ---------------------------------------------------------------- password + session
const readAuth = () => { try { return JSON.parse(fs.readFileSync(PASS_FILE, 'utf8')); } catch { return null; } };
const sign = (auth, payload) => crypto.createHmac('sha256', Buffer.from(auth.secret, 'base64')).update(payload).digest('base64url');
const makeSession = (auth) => { const exp = String(Date.now() + SESSION_MS); return `${exp}.${sign(auth, exp)}`; };

function validSession(auth, value) {
  if (!auth || !value) return false;
  const [exp, mac] = value.split('.');
  if (!exp || !mac || Number(exp) < Date.now()) return false;
  const want = Buffer.from(sign(auth, exp)), got = Buffer.from(mac);
  return want.length === got.length && crypto.timingSafeEqual(want, got);
}

function checkPassword(auth, password) {
  const hash = crypto.scryptSync(password, Buffer.from(auth.salt, 'base64'), 64);
  const want = Buffer.from(auth.hash, 'base64');
  return hash.length === want.length && crypto.timingSafeEqual(hash, want);
}

const cookiesOf = (req) => Object.fromEntries((req.headers.cookie || '').split(/;\s*/).map((c) => {
  const i = c.indexOf('=');
  if (i < 0) return [];
  try { return [c.slice(0, i), decodeURIComponent(c.slice(i + 1))]; } catch { return []; }
}).filter((p) => p.length === 2));

function basicOk(auth, header) {
  if (!auth || !/^Basic /i.test(header || '')) return null;                // null = no attempt made
  const text = Buffer.from(header.slice(6).trim(), 'base64').toString('utf8');
  const i = text.indexOf(':');
  if (i < 0) return false;
  const user = text.slice(0, i), password = text.slice(i + 1);
  const userOk = user.length === BASIC_USER.length && crypto.timingSafeEqual(Buffer.from(user), Buffer.from(BASIC_USER));
  return checkPassword(auth, password) && userOk;                           // always runs scrypt, so timing does not reveal the user name
}

// ---------------------------------------------------------------- brute-force limit: 5 failures per 10 minutes per address
const fails = new Map();
const ipOf = (req) => (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress;
const recent = (ip) => { const f = (fails.get(ip) || []).filter((t) => t > Date.now() - 600_000); fails.set(ip, f); return f; };
const locked = (ip) => recent(ip).length >= 5;
const fail = (ip) => fails.set(ip, [...recent(ip), Date.now()]);
setInterval(() => { for (const ip of fails.keys()) recent(ip); }, 600_000).unref();

// ---------------------------------------------------------------- helpers
/** Only ever send people back to a path on this same site. */
function safeNext(value) {
  const v = String(value || '');
  if (!v.startsWith('/') || v.startsWith('//') || v.startsWith('/\\') || /[\u0000-\u001f\\]/.test(v) || v.length > 2048) return '/';
  if (/^\/(login|logout)(\/|\?|$)/.test(v)) return '/';
  return v;
}
const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const HEADERS = {
  'Content-Security-Policy': "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
  'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex, nofollow',
};
const send = (res, code, body = '', type = 'text/html; charset=utf-8', extra = {}) => { res.writeHead(code, { ...HEADERS, 'Content-Type': type, ...extra }); res.end(body); };
const asset = (name) => fs.readFileSync(path.join(HERE, 'public', name), 'utf8');
const loginPage = (next, message = '') => asset('login.html').replace('<!--MSG-->', message).replace('<!--NEXT-->', escapeHtml(next));
const note = (text) => `<p class="msg" role="alert">${escapeHtml(text)}</p>`;
async function readBody(req, max) { let b = ''; for await (const c of req) { b += c; if (b.length > max) throw new Error('too large'); } return b; }

// ---------------------------------------------------------------- server
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const auth = readAuth();
  const secure = req.headers['x-forwarded-proto'] === 'https' ? '; Secure' : '';
  const ip = ipOf(req);
  const sessionOk = validSession(auth, cookiesOf(req)[COOKIE]);

  if (req.method === 'GET' && url.pathname === '/gate.css') return send(res, 200, asset('gate.css'), 'text/css; charset=utf-8');

  // ---- the question Caddy asks for every request
  if (url.pathname === '/verify') {
    if (sessionOk) return send(res, 200, 'ok', 'text/plain');
    if (!locked(ip)) {
      const basic = basicOk(auth, req.headers.authorization);
      if (basic === true) return send(res, 200, 'ok', 'text/plain');
      if (basic === false) fail(ip);
    }
    const original = req.headers['x-forwarded-uri'] || '/';
    const method = req.headers['x-forwarded-method'] || 'GET';
    const wantsPage = method === 'GET' && String(req.headers.accept || '').includes('text/html')
      && !original.startsWith('/ollama/') && !original.startsWith('/api/');
    if (wantsPage) return send(res, 302, '', 'text/plain', { Location: `/login?next=${encodeURIComponent(safeNext(original))}` });
    const extra = original.startsWith('/ollama/') ? { 'WWW-Authenticate': 'Basic realm="llm", charset="UTF-8"' } : {};
    return send(res, 401, 'unauthorized', 'text/plain', extra);
  }

  // ---- the login page
  if (url.pathname === '/login') {
    const next = safeNext(url.searchParams.get('next'));
    if (req.method === 'GET') {
      if (sessionOk) return send(res, 303, '', 'text/plain', { Location: next });
      return send(res, 200, loginPage(next, auth ? '' : note('Passord er ikke satt opp ennå.')));
    }
    if (req.method === 'POST') {
      let form;
      try { form = new URLSearchParams(await readBody(req, 2048)); } catch { return send(res, 413); }
      const target = safeNext(form.get('next'));
      if (!auth) return send(res, 503, loginPage(target, note('Passord er ikke satt opp ennå.')));
      if (locked(ip)) return send(res, 429, loginPage(target, note('For mange forsøk. Vent ti minutter.')));
      const password = form.get('password') || '';
      if (password && checkPassword(auth, password)) {
        fails.delete(ip);
        return send(res, 303, '', 'text/plain', { Location: target, 'Set-Cookie': `${COOKIE}=${encodeURIComponent(makeSession(auth))}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_MS / 1000}${secure}` });
      }
      fail(ip);
      await new Promise((r) => setTimeout(r, 600));                         // slow guessing down a little
      return send(res, 401, loginPage(target, note('Feil passord.')));
    }
  }

  if (req.method === 'POST' && url.pathname === '/logout') {
    if (req.headers.origin) { let ok = false; try { ok = new URL(req.headers.origin).host === req.headers.host; } catch { /* bad origin */ } if (!ok) return send(res, 403); }
    return send(res, 303, '', 'text/plain', { Location: '/login', 'Set-Cookie': `${COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${secure}` });
  }

  send(res, 404, 'not found', 'text/plain');
});
server.listen(PORT, HOST, () => console.log(`llm-gate listening on ${HOST}:${PORT} (${readAuth() ? 'password set' : 'LOCKED: run set-password.js'})`));
