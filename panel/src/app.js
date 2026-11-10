(function () {
'use strict';
/* injected at build time */
const BASE = "@@BASE@@";
const REGIONS = @@REGIONS@@;
const LAND_B64 = "@@LAND@@";

/* ------------------------------------------------------------------ utils */
const $ = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const ls = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* private mode */ } }
};
function ago(sec) {
  sec = Math.max(0, Math.round(sec));
  if (sec < 5) return 'just now';
  if (sec < 60) return sec + 's ago';
  if (sec < 3600) return Math.floor(sec / 60) + 'm ago';
  if (sec < 86400) return Math.floor(sec / 3600) + 'h ago';
  return Math.floor(sec / 86400) + 'd ago';
}
function dur(s) {
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return d ? d + 'd ' + h + 'h' : h ? h + 'h ' + m + 'm' : m + 'm ' + Math.floor(s % 60) + 's';
}
const IC = {
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="1"/><path d="M5 15V5a1 1 0 011-1h10"/></svg>',
  qr: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h3v3M20 14v6h-3"/></svg>',
  info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.5"/></svg>'
};
const SPIN = '<svg class="spin" viewBox="0 0 24 24" aria-hidden="true"><circle class="tr" cx="12" cy="12" r="9"/><circle class="ar" cx="12" cy="12" r="9"/></svg>';

/* ------------------------------------------------------------------ flags */
let emojiOk = null;
function emojiFlagsWork() {
  if (emojiOk !== null) return emojiOk;
  try {
    const c = document.createElement('canvas'); c.width = c.height = 24;
    const x = c.getContext('2d', { willReadFrequently: true });
    x.textBaseline = 'top';
    x.font = '20px "Apple Color Emoji","Segoe UI Emoji","Noto Color Emoji",sans-serif';
    x.fillText('\uD83C\uDDE8\uD83C\uDDED', 0, 0);           /* Switzerland: red, never grey */
    const d = x.getImageData(0, 0, 24, 24).data; let col = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 40 && (Math.abs(d[i] - d[i + 1]) > 40 || Math.abs(d[i + 1] - d[i + 2]) > 40)) col++;
    emojiOk = col > 12;
  } catch (e) { emojiOk = true; }
  return emojiOk;
}
function toFlag(cc) { return String.fromCodePoint.apply(null, cc.toUpperCase().split('').map(c => 0x1F1E6 + c.charCodeAt(0) - 65)); }
function flagHTML(cc) {
  if (!/^[A-Za-z]{2}$/.test(cc || '')) return '<span class="flag" aria-hidden="true">\uD83C\uDF10</span>';
  if (emojiFlagsWork()) return '<span class="flag" role="img" aria-label="' + esc(cc) + '">' + toFlag(cc) + '</span>';
  return '<img class="flag" src="https://flagcdn.com/48x36/' + cc.toLowerCase() + '.png" alt="' + esc(cc) + '" width="28" height="21" data-cc="' + esc(cc) + '">';
}
document.addEventListener('error', function (e) {          /* flag image blocked/offline -> plain code */
  const t = e.target;
  if (t && t.tagName === 'IMG' && t.dataset.cc) t.replaceWith(document.createTextNode(t.dataset.cc));
}, true);

/* ------------------------------------------------------------------ toasts / copy */
function toast(msg, bad) {
  const el = document.createElement('div');
  el.className = 'toast' + (bad ? ' bad' : '');
  el.textContent = msg;
  $('#toasts').appendChild(el);
  setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 320); }, bad ? 3600 : 2000);
}
async function copyText(t) {
  try { if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(t); return true; } } catch (e) { /* fall through */ }
  try {
    const a = document.createElement('textarea');
    a.value = t; a.setAttribute('readonly', ''); a.style.cssText = 'position:fixed;top:-100px;opacity:0';
    document.body.appendChild(a); a.select(); const ok = document.execCommand('copy'); a.remove(); return ok;
  } catch (e) { return false; }
}
async function copyWith(btn, text, what) {
  const ok = await copyText(text);
  toast(ok ? 'Copied ' + what : 'Copy blocked by the browser - select the text manually', !ok);
  if (ok && btn) {
    const old = btn.innerHTML; btn.classList.add('done'); btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="M5 12l5 5 9-10"/></svg>Copied';
    setTimeout(() => { btn.classList.remove('done'); btn.innerHTML = old; }, 1300);
  }
}

/* ------------------------------------------------------------------ flap counters */
function Flap(el, min) {
  let cells = [], cur = null;
  return function set(n) {
    n = Math.max(0, Math.floor(+n || 0));
    const s = String(n).padStart(min, '0');
    const fresh = cells.length !== s.length;
    if (fresh) {
      el.innerHTML = s.split('').map(() => '<span class="dg"><span class="col">' + '0123456789'.split('').map(d => '<i>' + d + '</i>').join('') + '</span></span>').join('');
      cells = $$('.dg', el);
    }
    const real = String(n).length;
    cells.forEach((c, i) => {
      const col = c.firstChild;
      col.style.transitionDelay = fresh ? '0ms' : ((cells.length - 1 - i) * 70) + 'ms';
      if (fresh) col.style.transition = 'none';
      col.style.transform = 'translateY(' + (-(+s[i]) * 1.12) + 'em)';
      c.classList.toggle('z', i < s.length - real);
    });
    if (fresh) { void el.offsetWidth; cells.forEach(c => c.firstChild.style.transition = ''); }
    el.setAttribute('role', 'img');
    el.setAttribute('aria-label', n.toLocaleString());
    cur = n;
  };
}
const fOnline = Flap($('#cOnline'), 3), fTotal = Flap($('#cTotal'), 4), fToday = Flap($('#cToday'), 3), fUnique = Flap($('#cUnique'), 4);
fOnline(0); fTotal(0); fToday(0); fUnique(0);

/* ------------------------------------------------------------------ api */
async function api(path, body, timeout) {
  const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), timeout || 8000);
  try {
    const r = await fetch(BASE + path, {
      method: body ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store', signal: ctl.signal,
      headers: body ? { 'Content-Type': 'application/json', 'X-Panel': '1' } : {},
      body: body ? JSON.stringify(body) : undefined
    });
    let data = null; try { data = await r.json(); } catch (e) { /* not json */ }
    return { status: r.status, ok: r.ok, data };
  } finally { clearTimeout(t); }
}

/* ------------------------------------------------------------------ state */
const S = {
  authed: false, server: null, stats: null, eps: [], cfg: null, ssh: [],
  edge: {}, fam: 'all', vr: 'ws', opts: null, nv: false, vid: null,
  lastOk: 0, fails: 0, detailAt: 0, sig: '', feedSig: '', prevUp: {}
};
(function ident() {
  let v = ls.get('sp_vid');
  if (!/^[a-f0-9]{16}$/.test(v || '')) {
    v = Array.from(crypto.getRandomValues(new Uint8Array(8))).map(b => b.toString(16).padStart(2, '0')).join('');
    ls.set('sp_vid', v);
  }
  S.vid = v;
  S.nv = Date.now() - (+ls.get('sp_last') || 0) > 30 * 60 * 1000;
})();

const SRC = { metadata: 'Google metadata server', hostname: 'run.app hostname', geoip: 'GeoIP of egress IP', env: 'PANEL_REGION setting', none: 'not detected' };
const FAM = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', ss: 'Shadowsocks', ssh: 'SSH' };
const VAR = { ws: 'WS', hu: 'HTTPUpgrade', xh: 'XHTTP', grpc: 'gRPC', h2: 'H2' };

/* ------------------------------------------------------------------ server block */
let shownRegion = null;
function setRegionCode(code) {
  if (code === shownRegion) return;
  shownRegion = code;
  const h = $('#regionCode');
  h.setAttribute('aria-label', 'Region ' + code);
  h.innerHTML = code.split('').map((c, i) => '<span style="--i:' + i + '" aria-hidden="true">' + (c === '-' ? '&#8209;' : esc(c)) + '</span>').join('');
  fitRegion();
}
function fitRegion() {
  const h = $('#regionCode'), avail = h.parentElement.clientWidth;
  if (!avail) return;
  h.style.fontSize = '100px';
  const w = h.scrollWidth || 1, max = Math.min(190, window.innerWidth * .115 + 20);
  h.style.fontSize = Math.max(34, Math.min(max, 100 * avail / w * .98)) + 'px';
}
window.addEventListener('resize', () => fitRegion());
if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitRegion);
function hostGuess() {
  const m = location.hostname.toLowerCase().match(/\.([a-z]+(?:-[a-z]+)*[0-9]+)\.run\.app$/);
  if (m && REGIONS[m[1]]) {
    const r = REGIONS[m[1]];
    return { region: m[1], city: r[0], country: r[1], cc: r[2], lat: r[3], lon: r[4], source: 'hostname', provider: 'Google Cloud Run', host: location.host };
  }
  return null;
}
function fmtCoord(lat, lon) {
  if (lat == null || lon == null) return '\u2014';
  return Math.abs(lat).toFixed(2) + '\u00B0' + (lat >= 0 ? 'N' : 'S') + ' ' + Math.abs(lon).toFixed(2) + '\u00B0' + (lon >= 0 ? 'E' : 'W');
}
let LAST_ST = null, LAST_STORE_ERR = '';
function renderServer(sv) {
  LAST_STORE_ERR = (sv && sv.store_error) || '';
  renderStoreNote();
  if (!sv) return;
  setRegionCode((sv.region && sv.region !== 'unknown' ? sv.region : 'unknown').toUpperCase());
  $('#city').textContent = sv.city || 'Unknown location';
  $('#country').textContent = sv.country ? '\u00B7 ' + sv.country : '';
  $('#flag').innerHTML = flagHTML(sv.cc);
  $('#mProv').textContent = sv.provider || '\u2014';
  $('#mSrc').textContent = SRC[sv.source] || sv.source || '\u2014';
  $('#mHost').textContent = sv.host || location.host;
  $('#mHost').title = sv.host || location.host;
  $('#mCoord').textContent = fmtCoord(sv.lat, sv.lon);
  if (sv.engine) {
    $('#mEng').textContent = (sv.engine || '').replace(/^./, c => c.toUpperCase()) + (sv.service ? ' \u00B7 ' + sv.service : '');
    $('#mUp').textContent = dur(sv.uptime_s || 0);
    $('#fNode').textContent = 'node ' + sv.node + (sv.revision ? ' \u00B7 ' + sv.revision : '');
  } else {
    $('#mEng').textContent = 'locked'; $('#mUp').textContent = 'locked';
  }
  Globe.setServer(sv);
}

/* ------------------------------------------------------------------ stats */
function renderStoreNote() {
  const st = LAST_ST;
  if (!st) return;
  const bits = [];
  if (st.synced === false) {
    // store_error only arrives for the signed-in admin; it names what Cloud Storage refused.
    const why = LAST_STORE_ERR ? ' <code>' + esc(LAST_STORE_ERR) + '</code>' : '';
    bits.push('<span class="warn"><b>Counter store unreachable</b>' + why + '</span>');
  }
  else if (st.store === 'gcs') bits.push('Counters shared via <b>Cloud Storage</b>.');
  else bits.push('Counters kept on <b>this node only</b>.');
  $('#storeNote').innerHTML = bits.join(' ');
  $('#storeNote').classList.toggle('warn', st.synced === false);
}
function renderStats(st) {
  if (!st) return;
  $('#ctrs').classList.remove('skel');
  fOnline(st.online); fTotal(st.total); fToday(st.today); fUnique(st.unique);
  $('#peak').textContent = st.peak ? 'peak ' + st.peak : '';
  const d = st.since ? new Date(st.since * 1000).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : null;
  $('#since').innerHTML = d ? 'Counting since <b>' + esc(d) + '</b> &middot; ' + (st.nodes > 1 ? '<b>' + st.nodes + '</b> nodes in sync' : 'one node') : '&nbsp;';
  renderChart(st.series || []);
  LAST_ST = st;
  renderStoreNote();
  Globe.setVisitors(st.visitors || []);
  renderFeed(st.feed);
}
let chartDone = false;
function renderChart(series) {
  const svg = $('#chart'), W = 560, H = 170, L = 30, B = 24, T = 20;
  const max = Math.max(1, ...series.map(s => s[1]));
  const bw = (W - L) / series.length, pad = Math.min(8, bw * .25);
  let h = '<line x1="' + L + '" x2="' + W + '" y1="' + (H - B) + '" y2="' + (H - B) + '" stroke="var(--line-2)"/>';
  h += '<text x="0" y="' + (T + 3) + '">' + max + '</text><text x="0" y="' + (H - B) + '">0</text>';
  series.forEach((s, i) => {
    const v = s[1], bh = Math.max(v ? 3 : 1, (H - B - T) * v / max), x = L + i * bw + pad / 2, y = H - B - bh;
    const dt = new Date(s[0] + 'T00:00:00Z');
    const lab = dt.toLocaleDateString(undefined, { day: 'numeric', month: 'short', timeZone: 'UTC' });
    h += '<g><title>' + esc(lab) + ': ' + v + ' visits</title><rect class="bar' + (i === series.length - 1 ? ' t' : '') + '" x="' + x.toFixed(1) + '" y="' + y.toFixed(1) + '" width="' + (bw - pad).toFixed(1) + '" height="' + bh.toFixed(1) + '" rx="1"/>' +
      '<text class="vl" x="' + (x + (bw - pad) / 2).toFixed(1) + '" y="' + (y - 5).toFixed(1) + '" text-anchor="middle">' + v + '</text></g>';
    if (i === 0 || i === series.length - 1 || i === 7) h += '<text x="' + (x + (bw - pad) / 2).toFixed(1) + '" y="' + (H - 6) + '" text-anchor="middle">' + esc(lab) + '</text>';
  });
  svg.innerHTML = h;
  if (!chartDone) { chartDone = true; requestAnimationFrame(() => requestAnimationFrame(() => svg.classList.add('in'))); } else svg.classList.add('in');
}
function renderFeed(feed) {
  const ul = $('#feed');
  if (!S.authed) {
    if (S.feedSig !== 'locked') { S.feedSig = 'locked'; ul.innerHTML = '<li class="empty">Unlock the panel to see where recent visitors came from.</li>'; }
    return;
  }
  feed = feed || [];
  const sig = JSON.stringify(feed);
  if (sig === S.feedSig) return;
  S.feedSig = sig;
  if (!feed.length) { ul.innerHTML = '<li class="empty">No visits recorded yet.</li>'; return; }
  const now = Date.now() / 1000;
  ul.innerHTML = feed.map(f => '<li>' + flagHTML(f.cc) + '<span>' + (f.city ? 'Visitor from ' + esc(f.city) : f.cc ? 'Visitor from ' + esc(f.cc) : 'Visitor') + '</span><span data-t="' + f.t + '">' + ago(now - f.t) + '</span></li>').join('');
}
setInterval(() => {                                  /* keep relative times honest */
  const now = Date.now() / 1000;
  $$('#feed [data-t]').forEach(e => e.textContent = ago(now - (+e.dataset.t)));
  if (S.lastOk) setStatus(true);
}, 1000);

/* ------------------------------------------------------------------ status chip */
function setStatus(ok) {
  const el = $('#status'), tx = $('#stText');
  el.classList.toggle('ok', ok); el.classList.toggle('bad', !ok);
  tx.textContent = ok ? 'live \u00B7 synced ' + ago((Date.now() - S.lastOk) / 1000).replace(' ago', ' ago') : 'offline \u00B7 retrying' + (S.fails > 1 ? ' (' + S.fails + ')' : '');
}

/* ------------------------------------------------------------------ share links */
/* Three separate values, never mixed up:
     Address = where the client dials   (IP / hostname)
     SNI     = name sent in the TLS hello
     Host    = HTTP Host header = the *.run.app service that must answer       */
const ADDR_PRE = { firebase: ['Firebase', 'firebase.google.com'], googleapis: ['Google APIs', 'www.googleapis.com'] };
const SNI_PRE = { firebase: ['Firebase', 'firebase.google.com'], googleapis: ['Google APIs', 'www.googleapis.com'], maya: ['Maya', 'maya.ph'] };
const HOST_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$/;
function validHost(v) {
  v = String(v || '');
  if (!v || v.length > 253) return false;
  if (HOST_RE.test(v)) return true;
  const six = v.replace(/^\[|\]$/g, '');
  return six.indexOf(':') > -1 && /^[0-9A-Fa-f:.]+$/.test(six);
}
function b64(s) { return btoa(unescape(encodeURIComponent(s))); }
function defaults() {
  return { host: location.hostname, port: location.port || '443', fp: 'chrome', addrMode: 'host', addr: '', sniMode: 'host', sni: '', insecure: false };
}
function loadOpts() {
  const d = defaults();
  try {
    const n = JSON.parse(ls.get('sp_opts2') || 'null');
    if (n && typeof n === 'object') return Object.assign(d, n);
    const old = JSON.parse(ls.get('sp_opts') || 'null');           /* migrate the first version's settings */
    if (old && typeof old === 'object') {
      if (old.port) d.port = String(old.port);
      if (old.fp) d.fp = old.fp;
      if (old.addr && old.addr !== location.hostname && validHost(old.addr)) { d.addrMode = 'custom'; d.addr = old.addr; }
      if (old.sni && old.sni !== location.hostname && validHost(old.sni)) { d.sniMode = 'custom'; d.sni = old.sni; }
    }
  } catch (e) { /* corrupt storage: start clean */ }
  return d;
}
function saveOpts() { ls.set('sp_opts2', JSON.stringify(S.opts)); }
/* resolve what the links will really contain - always complete and valid */
function eff(o) {
  const host = validHost(o.host) ? o.host : location.hostname;
  const pick = (mode, pre, custom) => mode === 'host' ? host : pre[mode] ? pre[mode][1] : (validHost(custom) ? custom : host);
  const port = /^\d+$/.test(String(o.port)) && +o.port > 0 && +o.port < 65536 ? String(o.port) : '443';
  return { host, addr: pick(o.addrMode, ADDR_PRE, o.addr), sni: pick(o.sniMode, SNI_PRE, o.sni), port, fp: o.fp || 'chrome', insecure: !!o.insecure };
}
function tp(ep, e) {
  const q = encodeURIComponent, p = [['security', 'tls'], ['sni', e.sni], ['fp', e.fp]];
  if (e.insecure) p.push(['allowInsecure', '1']);
  if (ep.network === 'ws') p.push(['type', 'ws'], ['host', e.host], ['path', ep.path]);
  else if (ep.network === 'httpupgrade') p.push(['type', 'httpupgrade'], ['host', e.host], ['path', ep.path]);
  else if (ep.network === 'xhttp' || ep.network === 'splithttp') p.push(['type', 'xhttp'], ['host', e.host], ['path', ep.path], ['mode', ep.mode || 'auto']);
  else if (ep.network === 'grpc') p.push(['type', 'grpc'], ['serviceName', ep.service], ['authority', e.host], ['mode', 'gun'], ['alpn', 'h2']);
  return p.map(kv => kv[0] + '=' + q(kv[1])).join('&');
}
function uriFor(ep, o) {
  const e = eff(o);
  if (ep.family === 'ssh') return 'wss://' + e.host + ep.path;
  const q = encodeURIComponent, host = e.addr.indexOf(':') > -1 && e.addr[0] !== '[' ? '[' + e.addr + ']' : e.addr;
  const label = 'saeka-' + ep.family + '-' + ep.variant + '-' + ((S.server && S.server.region) || 'srv');
  const hp = host + ':' + e.port;
  if (ep.family === 'vless') return 'vless://' + q(ep.cred.id) + '@' + hp + '?encryption=none&' + tp(ep, e) + '#' + q(label);
  if (ep.family === 'trojan') return 'trojan://' + q(ep.cred.password) + '@' + hp + '?' + tp(ep, e) + '#' + q(label);
  if (ep.family === 'ss') {
    const ui = b64(ep.cred.method + ':' + ep.cred.password).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    return 'ss://' + ui + '@' + hp + '?' + tp(ep, e) + '#' + q(label);
  }
  if (ep.family === 'vmess') {
    const net = ep.network === 'splithttp' ? 'xhttp' : ep.network;
    const j = { v: '2', ps: label, add: e.addr, port: e.port, id: ep.cred.id, aid: '0', scy: 'auto', net: net,
      type: net === 'grpc' ? 'gun' : net === 'xhttp' ? (ep.mode || 'auto') : 'none', host: e.host,
      path: net === 'grpc' ? ep.service : ep.path, tls: 'tls', sni: e.sni, fp: e.fp, alpn: net === 'grpc' ? 'h2' : '' };
    if (net === 'grpc') j.authority = e.host;
    return 'vmess://' + b64(JSON.stringify(j));
  }
  return '';
}
/* the same link as plain fields, for clients that want them typed in by hand */
function infoFor(ep, o) {
  const e = eff(o), net = (FAM[ep.family] || ep.family) + ' / ' + (VAR[ep.variant] || ep.variant);
  const L = [['Protocol', net]];
  if (ep.family === 'ssh') {
    L.push(['URL', 'wss://' + e.host + ep.path], ['Host', e.host], ['Path', ep.path]);
  } else {
    L.push(['Address', e.addr], ['Port', e.port], ['Host', e.host], ['SNI', e.sni]);
    L.push(ep.network === 'grpc' ? ['Service name', ep.service] : ['Path', ep.path]);
    if (ep.family === 'vless' || ep.family === 'vmess') L.push(['UUID', ep.cred.id]);
    else L.push(['Password', ep.cred.password]);
    if (ep.family === 'ss') L.push(['Method', ep.cred.method]);
    L.push(['TLS', 'tls'], ['Fingerprint', e.fp]);
    if (e.insecure) L.push(['Allow insecure', 'yes']);
    if (ep.mode && (ep.network === 'xhttp' || ep.network === 'splithttp')) L.push(['XHTTP mode', ep.mode]);
  }
  return L.map(r => r[0] + ': ' + r[1]).join('\n');
}

/* ------------------------------------------------------------------ QR */
function showQr(uri, title) {
  const cv = $('#qrCv');
  try {
    const qr = qrcode(0, 'L'); qr.addData(uri); qr.make();
    const n = qr.getModuleCount(), px = 6, quiet = 3, size = (n + quiet * 2) * px;
    cv.width = cv.height = size;
    const x = cv.getContext('2d');
    x.fillStyle = '#ece6d8'; x.fillRect(0, 0, size, size); x.fillStyle = '#12110f';
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) x.fillRect((c + quiet) * px, (r + quiet) * px, px, px);
  } catch (e) { toast('This link is too long for a QR code', true); return; }
  $('#dlgQrT').textContent = title || 'Scan to import';
  $('#qrUri').textContent = uri;
  $('#qrCopy').onclick = e => copyWith(e.currentTarget, uri, 'link');
  $('#dlgQr').showModal();
}

/* ------------------------------------------------------------------ access section */
function setLocked(locked) {
  $('#unlocked').hidden = locked;
  $('#lockedView').hidden = !locked;
  $('#accessBody').classList.toggle('lock', locked);
  $('#boardSec').hidden = locked;
  $('#copyAll').hidden = locked;
  $('#btnLock').textContent = locked ? 'Unlock' : 'Lock';
  $$('.lk').forEach(e => e.hidden = false);
}
function renderCreds() {
  const uniq = {};
  S.eps.forEach(e => {
    if (!e.cred) return;
    const k = e.family === 'vless' || e.family === 'vmess' ? 'id:' + e.family : 'pw:' + e.family;
    if (!uniq[k]) uniq[k] = e;
  });
  const items = [];
  const vl = uniq['id:vless'], vm = uniq['id:vmess'], tr = uniq['pw:trojan'], ss = uniq['pw:ss'];
  if (vl) items.push(['VLESS id', vl.cred.id, '']);
  if (vm) items.push(['VMess id', vm.cred.id, '']);
  if (tr) items.push(['Trojan password', tr.cred.password, '']);
  if (ss) items.push(['Shadowsocks password', ss.cred.password, ss.cred.method]);
  (S.ssh || []).forEach(u => items.push(['SSH \u00B7 ' + u.user, u.password || '(empty)', 'tunnel user']));
  const html = items.map((it, i) => '<div class="cred"><h3>' + esc(it[0]) + '<i>live</i></h3><div class="v"><code title="' + esc(it[1]) + '">' + esc(it[1]) + '</code><button class="btn ico" type="button" data-cp="' + i + '" aria-label="Copy ' + esc(it[0]) + '"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="11" height="11" rx="1"/><path d="M5 15V5a1 1 0 011-1h10"/></svg></button></div>' + (it[2] ? '<small>' + esc(it[2]) + '</small>' : '') + '</div>').join('');
  const box = $('#creds');
  if (box.dataset.sig !== html) { box.dataset.sig = html; box.innerHTML = html || '<div class="cred"><h3>No inbounds found</h3><small>The Xray config could not be read.</small></div>'; }
  $$('[data-cp]', box).forEach(b => b.onclick = () => copyWith(b, items[+b.dataset.cp][1], items[+b.dataset.cp][0]));
}
function renderLiveLine() {
  const c = S.cfg; if (!c) return;
  const t = c.mtime ? ago(Date.now() / 1000 - c.mtime) : 'unknown';
  $('#liveLine').innerHTML = '<span>config <b>' + esc(c.path.split('/').pop()) + '</b> modified ' + t + '</span><span><b>' + c.count + '</b> inbounds</span><span><b>' + c.up + '</b> listening</span>' +
    (c.error ? '<span style="color:var(--verm)">' + esc(c.error) + '</span>' : '');
}
function chips(el, items, cur, onPick) {
  el.innerHTML = items.map(i => '<button type="button" class="chip" aria-pressed="' + (i[0] === cur) + '" data-k="' + i[0] + '">' + esc(i[1]) + '</button>').join('');
  $$('.chip', el).forEach(b => b.onclick = () => onPick(b.dataset.k));
}
function renderFilters() {
  const fams = ['vless', 'vmess', 'trojan', 'ss', 'ssh'].filter(f => S.eps.some(e => e.family === f));
  const vars = ['ws', 'hu', 'xh', 'grpc', 'h2'].filter(v => S.eps.some(e => e.variant === v));
  chips($('#fFam'), [['all', 'All']].concat(fams.map(f => [f, FAM[f]])), S.fam, k => { S.fam = k; S.sig = ''; renderTickets(); renderFilters(); });
  chips($('#fVar'), [['all', 'All']].concat(vars.map(v => [v, VAR[v]])), S.vr, k => { S.vr = k; S.sig = ''; renderTickets(); renderFilters(); });
}
function shown() {
  return S.eps.filter(e => (S.fam === 'all' || e.family === S.fam) && (S.vr === 'all' || e.variant === S.vr || (e.family === 'ssh' && S.vr === 'ws')));
}
function statusLine(e) {
  const t = S.edge[e.tag];
  const up = e.up ? 'up' : 'down';
  let h = '<span class="dot"></span><span>inbound ' + up + (e.up && e.probe_ms != null ? ' <em>' + e.probe_ms + ' ms</em>' : '') + '</span>';
  if (t) h += t.busy ? '<span>&middot; ' + SPIN + '</span>' : t.ok ? '<span>&middot; edge <em>' + t.ms + ' ms</em></span>' : '<span style="color:var(--verm)">&middot; edge failed</span>';
  return h;
}
function renderTickets() {
  const list = shown(), o = S.opts;
  const sig = JSON.stringify([list.map(e => e.tag), o, S.eps.length, S.server && S.server.region]);
  const box = $('#tix');
  if (sig !== S.sig) {
    S.sig = sig;
    if (!list.length) { box.innerHTML = '<p class="note">Nothing matches this filter.</p>'; return; }
    box.innerHTML = list.map((e, i) => {
      const uri = uriFor(e, o), ok = e.supported !== false;
      const route = e.family === 'ssh' ? e.path : e.network === 'grpc' ? 'service: ' + e.service : e.path;
      return '<article class="tk' + (ok ? '' : ' off') + '" data-f="' + e.family + '" data-tag="' + esc(e.tag) + '" style="animation:tkin .6s var(--ease) backwards;animation-delay:' + Math.min(i, 12) * 45 + 'ms">' +
        '<div class="tk-main"><div class="tk-h"><b>' + esc(FAM[e.family] || e.family) + '</b><span>' + esc(VAR[e.variant] || e.variant) + '</span></div>' +
        '<p class="tk-p" title="' + esc(route) + '">' + esc(route) + '</p><p class="tk-u">' + esc(uri) + '</p>' +
        '<div class="tk-s ' + (e.up ? 'up' : 'down') + '" data-st>' + statusLine(e) + '</div>' +
        (e.note ? '<p class="tk-note">' + esc(e.note) + '</p>' : '') + '</div>' +
        '<div class="tk-stub"><button class="btn pri" type="button" data-copy ' + (ok ? '' : 'disabled') + '>' + IC.copy + 'Copy</button>' +
        (e.family === 'ssh' ? '' : '<button class="btn" type="button" data-qr ' + (ok ? '' : 'disabled') + '>' + IC.qr + 'QR</button>') +
        '<button class="btn" type="button" data-info ' + (ok ? '' : 'disabled') + '>' + IC.info + 'Info</button></div></article>';
    }).join('');
    $$('.tk', box).forEach(el => {
      const e = S.eps.find(x => x.tag === el.dataset.tag), uri = uriFor(e, o), what = (FAM[e.family] || '') + ' ' + (VAR[e.variant] || '') + ' link';
      const c = $('[data-copy]', el), q = $('[data-qr]', el), inf = $('[data-info]', el);
      if (c) c.onclick = () => copyWith(c, uri, what);
      if (inf) inf.onclick = () => copyWith(inf, infoFor(e, o), (FAM[e.family] || '') + ' connection details');
      if (q) q.onclick = () => showQr(uri, (FAM[e.family] || '') + ' \u00B7 ' + (VAR[e.variant] || ''));
    });
  } else {
    list.forEach(e => {
      const el = $('.tk[data-tag="' + e.tag + '"] [data-st]', box);
      if (el) { el.className = 'tk-s ' + (e.up ? 'up' : 'down'); el.innerHTML = statusLine(e); }
    });
  }
}
function renderBoard() {
  const body = $('#rows');
  if (!body.children.length || body.children.length !== S.eps.length) {
    body.innerHTML = S.eps.map(e => '<tr data-tag="' + esc(e.tag) + '"><td class="fam" style="color:var(--f-' + e.family + ')">' + esc(FAM[e.family] || e.family) + '</td><td>' + esc(VAR[e.variant] || e.variant) + '</td><td>' + esc(e.network === 'grpc' ? e.service : e.path) + '</td><td>' + e.port + '</td><td data-in></td><td data-ed></td><td data-en></td></tr>').join('');
  }
  S.eps.forEach(e => {
    const tr = $('tr[data-tag="' + e.tag + '"]', body); if (!tr) return;
    const was = S.prevUp[e.tag];
    $('[data-in]', tr).innerHTML = '<span class="pill ' + (e.up ? 'up' : 'down') + '"><span class="dot"></span>' + (e.up ? 'listening' + (e.probe_ms != null ? ' \u00B7 ' + e.probe_ms + ' ms' : '') : 'down') + '</span>';
    const t = S.edge[e.tag], ed = $('[data-ed]', tr);
    if (e.variant !== 'ws') ed.innerHTML = '<span class="pill na"><span class="dot"></span>n/a</span>';
    else if (!t) ed.innerHTML = '<span class="muted">not tested</span>';
    else if (t.busy) ed.innerHTML = SPIN + ' <span class="muted">testing</span>';
    else ed.innerHTML = t.ok ? '<span class="pill up"><span class="dot"></span>' + t.ms + ' ms</span>' : '<span class="pill down"><span class="dot"></span>' + esc(t.info || 'failed') + '</span>';
    $('[data-en]', tr).innerHTML = e.supported === false ? '<span class="pill down"><span class="dot"></span>not supported</span>' : '<span class="pill up"><span class="dot"></span>ok</span>' + (e.note ? ' <span class="muted" title="' + esc(e.note) + '">\u24D8</span>' : '');
    if (was !== undefined && was !== e.up) { tr.classList.remove('flash'); void tr.offsetWidth; tr.classList.add('flash'); }
    S.prevUp[e.tag] = e.up;
  });
}

/* ------------------------------------------------------------------ edge test */
function wsProbe(path, timeout) {
  return new Promise(res => {
    const t0 = performance.now(); let done = false, ws;
    const fin = (ok, info) => { if (done) return; done = true; clearTimeout(tm); try { ws && ws.close(); } catch (e) { /* noop */ } res({ ok, ms: ok ? Math.round(performance.now() - t0) : null, info }); };
    const tm = setTimeout(() => fin(false, 'timeout'), timeout || 7000);
    try {
      ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + path);
      ws.onopen = () => fin(true); ws.onerror = () => fin(false, 'refused'); ws.onclose = () => fin(false, 'closed');
    } catch (e) { fin(false, 'blocked'); }
  });
}
let testing = false;
async function testEdge() {
  if (testing) return; testing = true;
  const btn = $('#testAll'); btn.disabled = true; btn.innerHTML = SPIN + ' Testing';
  const list = S.eps.filter(e => e.variant === 'ws' && e.supported !== false);
  list.forEach(e => S.edge[e.tag] = { busy: true });
  renderBoard(); renderTickets();
  let i = 0;
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (i < list.length) {
      const e = list[i++]; S.edge[e.tag] = await wsProbe(e.path);
      renderBoard(); renderTickets();
    }
  }));
  const okN = list.filter(e => S.edge[e.tag].ok).length;
  toast(okN === list.length ? 'All ' + okN + ' WebSocket routes answered through the edge' : okN + ' of ' + list.length + ' WebSocket routes answered', okN !== list.length);
  btn.disabled = false; btn.textContent = 'Test edge'; testing = false;
}

/* ------------------------------------------------------------------ data flow */
function onPublic(d) {
  S.lastOk = Date.now(); S.fails = 0; setStatus(true);
  S.stats = d.stats;
  const wasAuthed = S.authed;
  if (d.server) S.server = Object.assign({}, S.server && S.server.engine ? S.server : {}, d.server);
  S.authed = !!d.authed;
  if (!S.authed && wasAuthed) { setLocked(true); toast('Session ended - unlock again', true); }
  renderServer(S.server);
  renderStats(d.stats);
  if (S.authed && Date.now() - S.detailAt > 5500) loadDetail();
}
async function loadDetail() {
  S.detailAt = Date.now();
  try {
    const r = await api('/api/server');
    if (r.status === 401) { S.authed = false; setLocked(true); renderFeed(); return; }
    if (!r.ok || !r.data) throw new Error('detail ' + r.status);
    const d = r.data, first = !S.eps.length;
    S.eps = d.endpoints || []; S.cfg = d.config; S.ssh = d.ssh_users || [];
    S.server = d.server; S.authed = true;
    if (!S.opts) { S.opts = loadOpts(); syncInputs(); }
    setLocked(false); renderServer(S.server); renderCreds(); renderLiveLine(); renderFilters(); renderTickets(); renderBoard();
    if (first) { document.dispatchEvent(new Event('unlocked')); setTimeout(testEdge, 900); setTimeout(() => scanServers(true), 1500); }
  } catch (e) { /* the pulse loop reports connectivity; keep last data */ }
}
function fillModes() {
  const opt = (v, t) => '<option value="' + v + '">' + esc(t) + '</option>';
  $('#fAddrMode').innerHTML = opt('host', 'Server host') + Object.keys(ADDR_PRE).map(k => opt(k, ADDR_PRE[k][0] + ' · ' + ADDR_PRE[k][1])).join('') + opt('custom', 'Custom…');
  $('#fSniMode').innerHTML = opt('host', 'Server host') + Object.keys(SNI_PRE).map(k => opt(k, SNI_PRE[k][0] + ' · ' + SNI_PRE[k][1])).join('') + opt('custom', 'Custom…');
}
fillModes();
function syncInputs() {
  const o = S.opts;
  $('#fHost').value = o.host; $('#fPort').value = o.port; $('#fFp').value = o.fp;
  $('#fAddrMode').value = o.addrMode; $('#fSniMode').value = o.sniMode;
  $('#fAddr').value = o.addr; $('#fSni').value = o.sni; $('#fInsecure').checked = !!o.insecure;
  $('#wAddr').hidden = o.addrMode !== 'custom'; $('#wSni').hidden = o.sniMode !== 'custom';
  $$('.bar .inp').forEach(i => i.style.borderColor = '');
  renderRoute();
}
function renderRoute() {
  if (!S.opts) return;
  const e = eff(S.opts);
  $('#route').innerHTML = 'Dial <b>' + esc(e.addr) + ':' + esc(e.port) + '</b> &rarr; TLS SNI <b>' + esc(e.sni) + '</b> &rarr; HTTP Host <b>' + esc(e.host) + '</b>' + (e.insecure ? ' &middot; <span class="warnt">certificate check off</span>' : '');
}
function optsChanged() { saveOpts(); S.sig = ''; renderRoute(); renderTickets(); }
const TEXT_FIELDS = { fHost: 'host', fPort: 'port', fAddr: 'addr', fSni: 'sni' };
Object.keys(TEXT_FIELDS).forEach(id => $('#' + id).addEventListener('input', ev => {
  const el = ev.target, v = el.value.trim(), key = TEXT_FIELDS[id];
  const bad = key === 'port' ? !(/^\d+$/.test(v) && +v > 0 && +v < 65536) : !validHost(v);
  el.style.borderColor = bad ? 'var(--verm)' : '';
  if (bad) return;
  S.opts[key] = v; optsChanged();
}));
$('#fFp').addEventListener('change', ev => { S.opts.fp = ev.target.value; optsChanged(); });
$('#fAddrMode').addEventListener('change', ev => {
  S.opts.addrMode = ev.target.value; $('#wAddr').hidden = S.opts.addrMode !== 'custom';
  if (S.opts.addrMode === 'custom') $('#fAddr').focus();
  optsChanged();
});
$('#fSniMode').addEventListener('change', ev => {
  const m = S.opts.sniMode = ev.target.value; $('#wSni').hidden = m !== 'custom';
  if (m === 'maya') { S.opts.insecure = true; $('#fInsecure').checked = true; toast('Certificate check turned off: the Maya name will not match the server certificate'); }
  else if (m !== 'custom') { S.opts.insecure = false; $('#fInsecure').checked = false; }
  if (m === 'custom') $('#fSni').focus();
  optsChanged();
});
$('#fInsecure').addEventListener('change', ev => { S.opts.insecure = ev.target.checked; optsChanged(); });
$('#fReset').addEventListener('click', () => { S.opts = defaults(); ls.set('sp_opts2', ''); ls.set('sp_opts', ''); syncInputs(); S.sig = ''; renderTickets(); toast('Reset to this server'); });
$('#copyAll').addEventListener('click', ev => {
  const list = shown().filter(x => x.supported !== false);
  if (!list.length) return toast('Nothing to copy with this filter', true);
  copyWith(ev.currentTarget, list.map(x => uriFor(x, S.opts)).join('\n'), list.length + ' links');
});

/* ------------------------------------------------------------------ find server */
const dlgSrv = $('#dlgSrv');
S.srv = { list: [], busy: false };
function setSrvCount(n) { const em = $('#srvCount'); em.hidden = !n; em.textContent = n || ''; }
function renderServers(d, err) {
  const ul = $('#srvList');
  if (d) { S.srv.list = d.servers || []; S.srv.store = d.store; S.srv.reg = d.error; }
  const list = S.srv.list, cur = S.opts ? eff(S.opts).host : location.hostname;
  setSrvCount(list.filter(x => x.up).length);
  const up = list.filter(x => x.up).length;
  $('#srvLead').textContent = !list.length ? 'No servers found yet.' :
    up + ' of ' + list.length + ' server' + (list.length === 1 ? '' : 's') + ' answering. Pick one to point every link at it' + (S.srv.store === 'gcs' ? '.' : ' (single-server registry: no shared bucket).');
  ul.innerHTML = list.map(x => {
    const st = x.up ? '<span class="pill up"><span class="dot"></span>' + (x.self ? 'online' : x.ms + ' ms') + '</span>' : '<span class="pill down"><span class="dot"></span>' + esc(x.err || 'down') + '</span>';
    const tags = (x.self ? '<span class="tag">this server</span>' : '') + (x.same_login ? '' : '<span class="tag bad">different login</span>') + (x.manual ? '<span class="tag">added</span>' : '');
    const inUse = x.host === cur;
    return '<li class="sv' + (x.up ? '' : ' off') + (inUse ? ' cur' : '') + '" data-host="' + esc(x.host) + '"><span class="sv-f">' + flagHTML(x.cc) + '</span>' +
      '<div class="sv-m"><b>' + esc((x.region || 'unknown').toUpperCase()) + '</b><small>' + esc(x.city ? x.city + (x.country ? ', ' + x.country : '') : x.service || '') + '</small><code title="' + esc(x.host) + '">' + esc(x.host) + '</code></div>' +
      '<div class="sv-s">' + st + tags + '</div>' +
      '<div class="sv-a"><button class="btn pri" type="button" data-use ' + (inUse || !x.up ? 'disabled' : '') + '>' + (inUse ? 'In use' : 'Use') + '</button>' +
      '<a class="btn" href="https://' + esc(x.host) + '/" target="_blank" rel="noopener noreferrer">Open</a>' +
      (x.self ? '' : '<button class="btn ico" type="button" data-del aria-label="Remove ' + esc(x.host) + '"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 7h14M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/></svg></button>') + '</div></li>';
  }).join('');
  $$('.sv', ul).forEach(li => {
    const h = li.dataset.host, u = $('[data-use]', li), x = $('[data-del]', li);
    if (u) u.onclick = () => { S.opts.host = h; $('#fHost').value = h; $('#fHost').style.borderColor = ''; optsChanged(); renderServers(); toast('Links now point at ' + h); };
    if (x) x.onclick = () => srvCall('/api/servers/forget', { host: h }, x);
  });
  $('#srvErr').textContent = err || (S.srv.reg ? 'Registry: ' + S.srv.reg : '');
}
async function scanServers(quiet) {
  if (S.srv.busy) return; S.srv.busy = true;
  const b = $('#srvScan'); if (!quiet) { b.disabled = true; b.innerHTML = SPIN + ' Scanning'; $('#srvLead').innerHTML = SPIN + ' Checking every server…'; }
  try {
    const r = await api('/api/servers', null, 20000);
    if (r.status === 401) { S.authed = false; setLocked(true); if (!quiet) { dlgSrv.close(); toast('Session ended - unlock again', true); } }
    else if (r.ok && r.data) renderServers(r.data);
    else if (!quiet) renderServers(null, (r.data && r.data.error) || 'Could not scan (HTTP ' + r.status + ')');
  } catch (e) { if (!quiet) renderServers(null, 'Could not reach the panel. Check your connection.'); }
  b.disabled = false; b.textContent = 'Scan again'; S.srv.busy = false;
}
async function srvCall(path, body, btn) {
  $('#srvErr').textContent = ''; if (btn) btn.disabled = true;
  try {
    const r = await api(path, body, 20000);
    if (r.ok && r.data) { renderServers(r.data); return true; }
    $('#srvErr').textContent = (r.data && r.data.error) || 'Request failed (HTTP ' + r.status + ')';
  } catch (e) { $('#srvErr').textContent = 'Could not reach the panel.'; }
  if (btn) btn.disabled = false; return false;
}
function openFind() {
  if (!S.authed) { toast('Unlock the panel first'); openLogin(); return; }
  dlgSrv.showModal(); renderServers(); scanServers();
}
$('#findServer').addEventListener('click', openFind);
$('#fFind').addEventListener('click', openFind);
$('#srvScan').addEventListener('click', () => scanServers());
$('#srvAdd').addEventListener('submit', async ev => {
  ev.preventDefault();
  const el = $('#srvHost'), v = el.value.trim(); if (!v) return;
  const btn = $('button', ev.target); btn.disabled = true; btn.innerHTML = SPIN;
  if (await srvCall('/api/servers/add', { host: v })) { el.value = ''; toast('Server added'); }
  btn.disabled = false; btn.textContent = 'Add';
});
$('#testAll').addEventListener('click', testEdge);

/* pulse loop */
let timer = 0, booted = false;
async function pulse() {
  clearTimeout(timer);
  try {
    const r = await api('/api/pulse', { vid: S.vid, nv: S.nv });
    if (r.ok && r.data && r.data.ok) {
      if (S.nv) { S.nv = false; }
      ls.set('sp_last', String(Date.now()));
      onPublic(r.data);
      bootStep(2);
    } else if (r.status === 429) { throw new Error('rate limited'); }
    else throw new Error('http ' + r.status);
  } catch (e) {
    S.fails++; setStatus(false);
    if (!booted) bootDone();
  }
  if (!document.hidden) timer = setTimeout(pulse, S.fails ? Math.min(30000, 4000 * Math.pow(2, Math.min(S.fails, 3))) : 4000);
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) pulse(); else clearTimeout(timer); });

/* ------------------------------------------------------------------ login */
const dlgLogin = $('#dlgLogin');
function openLogin() { $('#loginErr').textContent = ''; $('#keyIn').value = ''; dlgLogin.showModal(); setTimeout(() => $('#keyIn').focus(), 50); }
$('#btnLock').addEventListener('click', async () => {
  if (!S.authed) return openLogin();
  await api('/api/logout', {});
  S.authed = false; S.eps = []; S.sig = ''; S.feedSig = ''; setLocked(true); renderFeed(); Globe.setVisitors([]);
  S.server = Object.assign({}, S.server, { engine: undefined });
  renderServer(S.server); toast('Locked');
});
$('#ctaUnlock').addEventListener('click', openLogin);
$$('[data-close]').forEach(b => b.addEventListener('click', () => b.closest('dialog').close()));
$$('dialog').forEach(d => d.addEventListener('click', e => { if (e.target === d) d.close(); }));
$('#loginForm').addEventListener('submit', async e => {
  e.preventDefault();
  const go = $('#loginGo'), key = $('#keyIn').value;
  if (!key) return;
  go.disabled = true; go.innerHTML = SPIN + ' Checking';
  $('#loginErr').textContent = '';
  try {
    const r = await api('/api/login', { key });
    if (r.ok) {
      dlgLogin.close(); S.authed = true; S.detailAt = 0; toast('Unlocked');
      await loadDetail(); $('#access').scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' });
    } else {
      $('#loginErr').textContent = r.status === 429 ? 'Too many attempts. Wait a moment and try again.' : 'That key is not right.';
      dlgLogin.classList.remove('shake'); void dlgLogin.offsetWidth; dlgLogin.classList.add('shake'); $('#keyIn').select();
    }
  } catch (err) { $('#loginErr').textContent = 'Could not reach the server. Check your connection.'; }
  go.disabled = false; go.textContent = 'Unlock';
});

/* ------------------------------------------------------------------ boot */
function bootStep(n) {
  for (let i = 1; i <= 4; i++) { const li = $('#b' + i); if (!li) continue; li.className = i < n ? 'done' : i === n ? 'on' : ''; }
  if (n >= 2 && !booted) setTimeout(() => { for (let i = 1; i <= 4; i++) $('#b' + i).className = 'done'; setTimeout(bootDone, 450); }, 250);
}
function bootDone() { if (booted) return; booted = true; $('#boot').classList.add('off'); setTimeout(() => $('#boot').remove(), 700); }
setTimeout(bootDone, 6000);

/* ------------------------------------------------------------------ globe */
const Globe = (function () {
  const cv = $('#globe'), ctx = cv.getContext('2d'), wrap = $('#gw'), tip = $('#tip'), hudC = $('#hudC');
  const D = Math.PI / 180, TAU = Math.PI * 2;
  let W = 0, H = 0, R = 0, cx = 0, cy = 0, dpr = 1;
  let lon0 = -40, lat0 = 20, sLon = 0, sLat = 0, cLat = 1;
  let srv = null, vis = [], drag = null, lastTouch = 0, anim = null, hits = [], raf = 0, firstFocus = true;
  const cs = getComputedStyle(document.documentElement), col = n => cs.getPropertyValue(n).trim();
  const C = { ink2: col('--ink-2'), line: col('--line'), line2: col('--line-2'), chalk: col('--chalk'), chalk2: col('--chalk-2'), muted: col('--muted'), amber: col('--amber'), dim: col('--dim') };
  const bin = atob(LAND_B64), mask = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) mask[i] = bin.charCodeAt(i);
  function isLand(lat, lon) {
    const r = Math.max(0, Math.min(179, Math.floor(90 - lat))), c = ((Math.floor(lon + 180) % 360) + 360) % 360, i = r * 360 + c;
    return (mask[i >> 3] >> (i & 7)) & 1;
  }
  const dLat = [], dLon = [], dSin = [], dCos = [];
  for (let lat = -84; lat <= 84; lat += 2) {
    const c = Math.cos(lat * D), n = Math.max(1, Math.round(360 * c / 2));
    for (let i = 0; i < n; i++) {
      const lon = -180 + (i + .5) * 360 / n;
      if (isLand(lat, lon)) { dLat.push(lat * D); dLon.push(lon * D); dSin.push(Math.sin(lat * D)); dCos.push(c); }
    }
  }
  function view(wx, wy, wz, o) {              /* world unit vector -> view space */
    const cl = Math.cos(lon0 * D), sl = Math.sin(lon0 * D);
    const x = wx * cl - wz * sl, z0 = wz * cl + wx * sl;
    o[0] = x; o[1] = wy * cLat - z0 * sLat; o[2] = wy * sLat + z0 * cLat;
  }
  const P = [0, 0, 0], Q = [0, 0, 0];
  function geo(latR, lonR, o) { const c = Math.cos(latR); view(c * Math.sin(lonR), Math.sin(latR), c * Math.cos(lonR), o); }
  const SX = x => cx + R * x, SY = y => cy - R * y;

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = wrap.clientWidth; H = wrap.clientHeight; if (!W || !H) return;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    cx = W / 2; cy = H / 2; R = Math.min(W, H) / 2 - 34;
    draw(performance.now());
  }
  function ease(t) { return 1 - Math.pow(1 - t, 4); }
  function focusTo(lo, la, ms) {
    let d = ((lo - lon0 + 540) % 360) - 180;
    anim = { t0: performance.now(), ms: ms || 1500, a: lon0, b: lon0 + d, c: lat0, d: Math.max(-70, Math.min(70, la)) };
    if (reduce) { lon0 = anim.b; lat0 = anim.d; anim = null; draw(performance.now()); }
  }
  function setServer(sv) {
    const had = srv && srv.lat === sv.lat && srv.lon === sv.lon;
    srv = sv && sv.lat != null ? sv : null;
    hudC.innerHTML = srv ? '<b>' + esc(fmtCoord(srv.lat, srv.lon)) + '</b> &middot; ' + esc((srv.region || '').toUpperCase()) : '&nbsp;';
    if (srv && !had) {
      if (firstFocus) { lon0 = srv.lon - 150; lat0 = srv.lat * .4; firstFocus = false; focusTo(srv.lon, srv.lat * .8 + 6, 2600); }
      else focusTo(srv.lon, srv.lat * .8 + 6, 1500);
    }
    draw(performance.now());
  }
  function setVisitors(v) { vis = (v || []).filter(x => x.lat != null); }

  function strokePoly(pts) {
    let on = false; ctx.beginPath();
    for (const p of pts) {
      if (p[2] > 0) { if (on) ctx.lineTo(SX(p[0]), SY(p[1])); else { ctx.moveTo(SX(p[0]), SY(p[1])); on = true; } } else on = false;
    }
    ctx.stroke();
  }
  function draw(t) {
    if (!W) return;
    if (anim) {
      const k = Math.min(1, (t - anim.t0) / anim.ms), e = ease(k);
      lon0 = anim.a + (anim.b - anim.a) * e; lat0 = anim.c + (anim.d - anim.c) * e;
      if (k >= 1) anim = null;
    } else if (!drag && srv && !reduce && t - lastTouch > 7000) {            /* idle: sway around the server */
      const tl = srv.lon + 24 * Math.sin(t / 7500), ta = Math.max(-60, Math.min(60, srv.lat * .8 + 6));
      lon0 += (tl - lon0) * .02; lat0 += (ta - lat0) * .02;
    }
    sLon = Math.sin(lon0 * D); sLat = Math.sin(lat0 * D); cLat = Math.cos(lat0 * D);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
    hits = [];
    /* bezel */
    ctx.save(); ctx.translate(cx, cy); ctx.strokeStyle = C.line2; ctx.lineWidth = 1;
    for (let a = 0; a < 360; a += 5) {
      const mj = a % 30 === 0, r1 = R + 9, r2 = R + (mj ? 23 : 15), s = Math.sin(a * D), c = Math.cos(a * D);
      ctx.beginPath(); ctx.moveTo(s * r1, -c * r1); ctx.lineTo(s * r2, -c * r2); ctx.stroke();
    }
    ctx.restore();
    /* sphere */
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, TAU); ctx.fillStyle = C.ink2; ctx.fill(); ctx.strokeStyle = C.line2; ctx.lineWidth = 1.2; ctx.stroke();
    /* graticule */
    ctx.strokeStyle = C.line; ctx.lineWidth = 1;
    for (let lo = -180; lo < 180; lo += 30) { const pts = []; for (let la = -90; la <= 90; la += 6) { geo(la * D, lo * D, P); pts.push([P[0], P[1], P[2]]); } strokePoly(pts); }
    for (let la = -60; la <= 60; la += 30) { const pts = []; for (let lo = -180; lo <= 180; lo += 6) { geo(la * D, lo * D, P); pts.push([P[0], P[1], P[2]]); } strokePoly(pts); }
    /* land */
    const s = Math.max(1.5, R / 170);
    ctx.fillStyle = C.chalk2;
    for (let i = 0; i < dLat.length; i++) {
      const c = dCos[i], l = dLon[i];
      view(c * Math.sin(l), dSin[i], c * Math.cos(l), P);
      if (P[2] > 0.03) { ctx.globalAlpha = .18 + .72 * P[2]; ctx.fillRect(SX(P[0]) - s / 2, SY(P[1]) - s / 2, s, s); }
    }
    ctx.globalAlpha = 1;
    /* server */
    let sp = null;
    if (srv) { geo(srv.lat * D, srv.lon * D, Q); sp = [Q[0], Q[1], Q[2]]; }
    /* visitors + arcs */
    if (sp) {
      const sc = Math.cos(srv.lat * D), sw = [sc * Math.sin(srv.lon * D), Math.sin(srv.lat * D), sc * Math.cos(srv.lon * D)];
      vis.forEach((v, idx) => {
        const vc = Math.cos(v.lat * D), vw = [vc * Math.sin(v.lon * D), Math.sin(v.lat * D), vc * Math.cos(v.lon * D)];
        const dot = Math.max(-1, Math.min(1, sw[0] * vw[0] + sw[1] * vw[1] + sw[2] * vw[2])), om = Math.acos(dot);
        if (om > .02) {
          const so = Math.sin(om), pts = [], N = 36;
          for (let i = 0; i <= N; i++) {
            const k = i / N, a = Math.sin((1 - k) * om) / so, b = Math.sin(k * om) / so, lift = 1 + .22 * (om / Math.PI) * Math.sin(Math.PI * k) * 2;
            view((vw[0] * a + sw[0] * b) * lift, (vw[1] * a + sw[1] * b) * lift, (vw[2] * a + sw[2] * b) * lift, P);
            pts.push([P[0], P[1], P[2]]);
          }
          ctx.strokeStyle = C.amber; ctx.globalAlpha = .45; ctx.lineWidth = 1.2; strokePoly(pts); ctx.globalAlpha = 1;
          if (!reduce) {
            const k = ((t / (2600 + om * 900)) + idx * .37) % 1, p = pts[Math.round(k * N)];
            if (p && p[2] > 0) { ctx.fillStyle = C.amber; ctx.beginPath(); ctx.arc(SX(p[0]), SY(p[1]), 2.4, 0, TAU); ctx.fill(); }
          }
        }
        geo(v.lat * D, v.lon * D, P);
        if (P[2] > 0) {
          const x = SX(P[0]), y = SY(P[1]);
          ctx.fillStyle = C.chalk; ctx.beginPath(); ctx.arc(x, y, 3.2, 0, TAU); ctx.fill();
          ctx.strokeStyle = C.chalk; ctx.globalAlpha = .4; ctx.beginPath(); ctx.arc(x, y, 6.5, 0, TAU); ctx.stroke(); ctx.globalAlpha = 1;
          hits.push({ x, y, k: 'v', d: v });
        }
      });
    }
    if (sp) {
      const x = SX(sp[0]), y = SY(sp[1]);
      if (sp[2] > 0) {
        if (!reduce) for (let k = 0; k < 3; k++) {
          const p = ((t / 2200) + k / 3) % 1;
          ctx.strokeStyle = C.amber; ctx.globalAlpha = (1 - p) * .6; ctx.lineWidth = 1.5;
          ctx.beginPath(); ctx.arc(x, y, 6 + p * 36, 0, TAU); ctx.stroke();
        }
        ctx.globalAlpha = 1;
        ctx.fillStyle = C.amber; ctx.beginPath(); ctx.arc(x, y, 5.5, 0, TAU); ctx.fill();
        ctx.strokeStyle = C.ink2; ctx.lineWidth = 2; ctx.stroke();
        /* label with leader */
        const code = (srv.region || '').toUpperCase(), city = (srv.city || '').split(',')[0];
        ctx.font = '600 12px "JetBrains Mono",ui-monospace,monospace';
        const w = Math.max(ctx.measureText(code).width, ctx.measureText(city).width) + 4, dir = x + 30 + w > W - 4 ? -1 : 1;
        ctx.strokeStyle = C.amber; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(x + dir * 7, y - 7); ctx.lineTo(x + dir * 28, y - 28); ctx.lineTo(x + dir * (28 + w), y - 28); ctx.stroke();
        ctx.textAlign = dir > 0 ? 'left' : 'right'; ctx.fillStyle = C.amber; ctx.fillText(code, x + dir * 32, y - 33);
        ctx.fillStyle = C.chalk2; ctx.font = '400 11px "JetBrains Mono",ui-monospace,monospace'; ctx.fillText(city, x + dir * 32, y - 14);
        hits.push({ x, y, k: 's', d: srv });
      } else {                                      /* server is on the far side: point at it from the rim */
        const a = Math.atan2(-sp[1], sp[0]), rx = cx + Math.cos(a) * (R + 36), ry = cy + Math.sin(a) * (R + 36);
        ctx.save(); ctx.translate(rx, ry); ctx.rotate(a); ctx.fillStyle = C.amber; ctx.beginPath(); ctx.moveTo(8, 0); ctx.lineTo(-6, -6); ctx.lineTo(-6, 6); ctx.fill(); ctx.restore();
        hits.push({ x: rx, y: ry, k: 's', d: srv });
      }
    }
  }
  function loop(t) { raf = 0; if (document.hidden) return; draw(t); if (!reduce) raf = requestAnimationFrame(loop); }
  function kick() { if (!raf) raf = requestAnimationFrame(loop); }

  /* interaction */
  cv.addEventListener('pointerdown', e => { cv.setPointerCapture(e.pointerId); drag = { x: e.clientX, y: e.clientY }; anim = null; lastTouch = performance.now(); cv.classList.add('drag'); tip.classList.remove('on'); });
  cv.addEventListener('pointermove', e => {
    const b = cv.getBoundingClientRect();
    if (drag) {
      const k = 60 / R; lon0 -= (e.clientX - drag.x) * k; lat0 = Math.max(-75, Math.min(75, lat0 + (e.clientY - drag.y) * k));
      drag = { x: e.clientX, y: e.clientY }; lastTouch = performance.now(); if (reduce) draw(lastTouch); return;
    }
    const mx = e.clientX - b.left, my = e.clientY - b.top; let best = null, bd = 16;
    hits.forEach(h => { const d = Math.hypot(h.x - mx, h.y - my); if (d < bd) { bd = d; best = h; } });
    if (best) {
      const d = best.d;
      tip.innerHTML = best.k === 's' ? esc((d.region || '').toUpperCase()) + '<small>' + esc(d.city || '') + '</small>' : flagHTML(d.cc) + ' ' + esc(d.city || d.cc || 'Visitor') + '<small>visitor</small>';
      tip.style.left = best.x + 'px'; tip.style.top = best.y + 'px'; tip.classList.add('on');
    } else tip.classList.remove('on');
  });
  const end = () => { drag = null; cv.classList.remove('drag'); };
  cv.addEventListener('pointerup', end); cv.addEventListener('pointercancel', end);
  cv.addEventListener('dblclick', () => srv && focusTo(srv.lon, srv.lat * .8 + 6));
  $('#recenter').addEventListener('click', () => { if (srv) { lastTouch = 0; focusTo(srv.lon, srv.lat * .8 + 6); } else toast('Region not detected yet', true); });
  new ResizeObserver(resize).observe(wrap);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) kick(); });
  resize(); kick();
  return { setServer, setVisitors, recenter: () => srv && focusTo(srv.lon, srv.lat * .8 + 6) };
})();

/* ------------------------------------------------------------------ reveal on scroll + start */
if ('IntersectionObserver' in window) {
  const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { threshold: .08 });
  $$('.rv').forEach(el => io.observe(el));
} else $$('.rv').forEach(el => el.classList.add('in'));

setLocked(true);
const g = hostGuess();
if (g) { S.server = g; renderServer(g); }
bootStep(1);
pulse();
})();
