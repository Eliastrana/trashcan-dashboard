const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };
const LABEL = { up: 'oppe', slow: 'treg', down: 'nede', unknown: '?' };
const BUSY = { stop: 'Setter på pause …', start: 'Starter …', restart: 'Starter på nytt …' };
let anyBusy = false;

async function control(s, action) {
  if (action === 'restart' && !confirm(`Starte «${s.name}» på nytt?${s.id === 'minecraft' ? '\n\nSpillerne kobles fra. Spillet lagres først, og det tar noen minutter.' : ''}`)) return;
  if (action === 'stop' && !confirm(`Sette «${s.name}» på pause?\n\nDen er nede til du trykker Start igjen, eller til maskinen starter på nytt.`)) return;
  try {
    const res = await fetch('/api/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'status-page' },
      body: JSON.stringify({ id: s.id, action }),
    });
    if (!res.ok) { const e = await res.json().catch(() => ({})); alert(e.error || `Feilet (${res.status})`); }
  } catch { alert('Fikk ikke kontakt med statussiden.'); }
  refresh();
}

// Small line icons, drawn here so the page needs no files or libraries. Built with DOM calls, never innerHTML.
const SVG_NS = 'http://www.w3.org/2000/svg';
const ICONS = {
  restart: ['M20 12a8 8 0 1 1-2.6-5.9', 'M20 4v5h-5'],
  stop: ['M8 5v14', 'M16 5v14'],
  start: ['M7 4.5v15l12-7.5z'],
};
// logos that are plain black, which are flipped to white in dark mode (see app.css)
const MONO = new Set(['ollama', 'ssh', 'lock']);
function icon(name) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  for (const d of ICONS[name]) {
    const p = document.createElementNS(SVG_NS, 'path');
    p.setAttribute('d', d);
    svg.append(p);
  }
  return svg;
}

function controlCell(s) {
  const cell = el('td', 'ctl');
  if (s.busy) { cell.append(el('span', 'working', BUSY[s.busy] || 'Jobber …')); return cell; }
  const add = (label, action) => {
    const b = el('button', `icon ${action}`);
    b.type = 'button';
    b.title = label;
    b.setAttribute('aria-label', `${label}: ${s.name}`);
    b.append(icon(action));
    b.addEventListener('click', () => control(s, action));
    cell.append(b);
  };
  if (s.controls.includes('restart')) add('Start på nytt', 'restart');
  if (s.controls.includes('stop') && (s.state === 'up' || s.state === 'slow')) add('Sett på pause', 'stop');
  if (s.controls.includes('start') && s.state === 'down') add('Start', 'start');
  return cell;
}

function fmtUptime(s) {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
  return d ? `${d} d ${h} t` : `${h} t ${Math.floor((s % 3600) / 60)} min`;
}

function row(dl, label, value, note, level) {
  dl.append(el('dt', null, label));
  const dd = el('dd', level || '', value);
  if (note) { dd.append(' '); dd.append(el('small', null, note)); }
  dl.append(dd);
}

// A flat bar that fills up to a percentage, with the figure next to it. The width is set through the style object
// (allowed by the page's security policy), never as markup.
function meterRow(dl, label, pct, value, note, level, hint) {
  dl.append(el('dt', null, label));
  const dd = el('dd', `meterrow ${level || ''}`);
  const meter = el('span', 'meter');
  meter.setAttribute('role', 'img');
  meter.setAttribute('aria-label', `${label}: ${value}`);
  const fill = el('span', 'fill');
  fill.style.width = `${Math.max(0, Math.min(100, pct))}%`;
  meter.append(fill);
  dd.append(meter, el('strong', null, value));
  if (note) dd.append(' ', el('small', null, note));
  if (hint) dd.title = hint;
  dl.append(dd);
}

// How busy the machine has been over the last 1, 5 and 15 minutes, as three short bars one above the other, so a
// rising or falling trend can be seen at a glance. 100 % means every core fully taken; more than that means a queue.
function loadRow(dl, pcts) {
  dl.append(el('dt', null, 'Belastning'));
  const dd = el('dd', 'loadrow');
  dd.title = 'Gjennomsnittlig belastning over tre tidsrom. 100 % betyr at alle kjernene er helt opptatt, mer enn det betyr at oppgaver må vente i kø.';
  [['1 min', pcts[0]], ['5 min', pcts[1]], ['15 min', pcts[2]]].forEach(([label, pct]) => {
    const level = pct > 100 ? 'bad' : pct > 70 ? 'warn' : '';
    const line = el('div', `loadline ${level}`);
    const meter = el('span', 'meter');
    meter.setAttribute('role', 'img');
    meter.setAttribute('aria-label', `Belastning siste ${label}: ${pct} %`);
    const fill = el('span', 'fill');
    fill.style.width = `${Math.max(0, Math.min(100, pct))}%`;
    meter.append(fill);
    line.append(el('small', 'when', label), meter, el('strong', null, `${pct} %`));
    dd.append(line);
  });
  dl.append(dd);
}

function renderMachine(m) {
  const dl = $('machine');
  dl.replaceChildren();
  if (!m) return;
  // The three "load" figures from the OS are the average number of jobs wanting a core, over 1, 5 and 15 minutes.
  // Divided by the number of cores they read as a share of the machine's capacity (over 100 % means a queue).
  const loadPct = m.load.map((n) => Math.round((n / m.cores) * 100));
  const busy = m.cpuPct ?? loadPct[0];
  meterRow(dl, 'Prosessor', busy, `${busy} %`, `i bruk av ${m.cores} kjerner`, busy >= 90 ? 'bad' : busy >= 65 ? 'warn' : '',
    'Hvor stor del av tiden kjernene har vært opptatt det siste minuttet.');
  loadRow(dl, loadPct);
  if (m.memUsedGB !== null) {
    const memPct = Math.round((m.memUsedGB / m.memTotalGB) * 100);
    meterRow(dl, 'Minne', memPct, `${memPct} %`, `${m.memUsedGB} av ${m.memTotalGB} GB`, memPct >= 90 ? 'warn' : '');
  }
  if (m.disk) meterRow(dl, 'Disk', m.disk.usedPct, `${m.disk.usedPct} %`, `brukt · ${m.disk.freeGB} av ${m.disk.totalGB} GB ledig`, m.disk.usedPct >= 95 ? 'bad' : m.disk.usedPct >= 85 ? 'warn' : '');
  row(dl, 'Oppetid', fmtUptime(m.uptimeS));
}

function renderServices(list, showControls) {
  const body = $('services');
  body.replaceChildren();
  let group = null;
  for (const s of list) {
    if (s.group !== group) {
      group = s.group;
      const g = el('tr', 'group');
      const c = el('td', null, group); c.colSpan = 6;
      g.append(c); body.append(g);
    }
    const tr = el('tr', `svc ${s.state}`);
    const name = el('td', 'name');
    const wrap = el('div', 'namewrap');
    if (s.icon) {
      const img = el('img', `logo ${MONO.has(s.icon) ? 'mono' : ''}`);
      img.src = `/icons/${s.icon}.svg`; img.alt = ''; img.width = 24; img.height = 24;
      wrap.append(img);
    }
    const text = el('div', 'nametext', s.name);
    wrap.append(text); name.append(wrap);
    if (s.url) {
      const line = el('span', 'url');
      if (/^https?:\/\//.test(s.url)) {
        const a = el('a', null, s.url.replace(/^https?:\/\//, ''));
        a.href = s.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
        line.append(a);
      } else line.textContent = s.url;
      text.append(line);
    }
    const notes = [];
    if (s.certDays !== null) notes.push(`sertifikat ${s.certDays} d`);
    if (s.state === 'down' && s.detail) notes.push(s.detail);
    if (notes.length) text.append(el('span', 'detail', notes.join(' · ')));
    tr.append(
      name,
      el('td', 'st', ''),
      el('td', 'num r hide-s', s.ms === null ? '–' : `${s.ms} ms`),
      el('td', 'num r hide-s', s.uptimePct === null ? '–' : `${s.uptimePct} %`),
    );
    tr.children[1].append(el('span', 'state', LABEL[s.state]));
    const cell = el('td', 'barcell');
    const bar = el('span', 'bar');
    bar.setAttribute('aria-hidden', 'true');
    for (const b of s.buckets) bar.append(el('i', b === null ? '' : b ? 'ok' : 'bad'));
    cell.append(bar); tr.append(cell);
    if (showControls) tr.append(controlCell(s));
    body.append(tr);
  }
}

// The headline: a large sentence with a status dot. Green means everything is operational and gets the pulsing "ping"
// ring (the same idea as Tailwind's animate-ping); a problem gets a still amber or red dot.
function setSummary(kind, text) {
  const sum = $('summary');
  const dot = el('span', `pulse ${kind}`);
  dot.setAttribute('aria-hidden', 'true');
  if (kind === 'ok') dot.append(el('span', 'ping'));
  dot.append(el('span', 'dot'));
  sum.replaceChildren(el('span', `status-line ${kind}`));
  sum.firstChild.append(dot, el('span', 'text', text));
}

function render(data) {
  const down = data.services.filter((s) => s.state === 'down').length;
  const slow = data.services.filter((s) => s.state === 'slow').length;
  if (down) setSummary('bad', `${down} ${down === 1 ? 'tjeneste' : 'tjenester'} nede`);
  else if (slow) setSummary('warn', `${slow} ${slow === 1 ? 'tjeneste' : 'tjenester'} treg`);
  else setSummary('ok', 'Alt er oppe');
  $('updated').textContent = data.at ? `Sist målt ${new Date(data.at).toLocaleTimeString('nb-NO')}. Siden oppdaterer seg selv.` : 'Venter på første måling.';
  renderMachine(data.machine);
  $('ctl-head').hidden = !data.controlsEnabled;
  anyBusy = data.services.some((s) => s.busy);
  renderServices(data.services, data.controlsEnabled);
}

async function refresh() {
  try {
    const res = await fetch('/api/status', { cache: 'no-store' });
    if (res.status === 401) { location.href = '/login'; return; }
    render(await res.json());
  } catch {
    setSummary('bad', 'Får ikke kontakt med statussiden');
  }
}
refresh();
setInterval(refresh, 30000);
setInterval(() => { if (anyBusy) refresh(); }, 3000);   // follow a restart closely while it is running
