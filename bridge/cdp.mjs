// bridge/cdp.mjs — Chrome DevTools Protocol helpers used to drive Bionic's
// OWN UI for remote approve/deny (M3a). The choice is clicked through Bionic's
// real code path (not a raw DB write, which it would not pick up and could
// corrupt). Requires Bionic to be running with a remote-debugging port.
//
// Pure module, no side effects, so it can be unit-tested against a mock
// Chromium without starting the bridge server.

const CDP_HOST = process.env.CDP_HOST || '127.0.0.1';
const CDP_PORT = Number(process.env.CDP_PORT || 9222);
const CDP_TIMEOUT_MS = Number(process.env.CDP_TIMEOUT_MS || 8000);
const CDP_MAX_BODY = 1e6;

function readBody(req, limit = CDP_MAX_BODY) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function cdpListTargets() {
  for (const p of ['/json', '/json/list']) {
    try {
      const r = await fetch(`http://${CDP_HOST}:${CDP_PORT}${p}`);
      if (r.ok) {
        const j = await r.json();
        if (Array.isArray(j)) return j;
      }
    } catch { /* try the next endpoint */ }
  }
  throw new Error(`CDP not reachable at ${CDP_HOST}:${CDP_PORT}`);
}

// Choose the page most likely to be the Bionic desktop app. Scores by
// title/url keywords; with a single page it is the only candidate.
function pickBionicPage(targets) {
  const pages = (targets || []).filter((t) => t && t.type === 'page' && t.webSocketDebuggerUrl);
  if (pages.length === 0) return null;
  const score = (t) => {
    const s = ((t.title || '') + ' ' + (t.url || '')).toLowerCase();
    let sc = 0;
    if (s.includes('bionic')) sc += 100;
    if (s.includes('lmstudio')) sc += 50;
    if (s.includes('agent') || s.includes('session')) sc += 10;
    return sc;
  };
  pages.sort((a, b) => score(b) - score(a));
  return pages[0];
}

// Build a self-contained JS expression that finds the button whose visible
// text matches the choice label and clicks it. Matching is on normalized
// (lowercased, whitespace-collapsed) text, so it is robust to Bionic's markup
// and relies on Bionic's OWN rendered label rather than CSS classes. No regex,
// no backslashes — split-based normalization only.
function cdpClickExpression(label) {
  return `
(function(){
  var target=${JSON.stringify(label)};
  function norm(s){ return (s||'').toLowerCase().split(' ').filter(function(x){return x.length>0;}).join(' '); }
  var want=norm(target);
  var els=document.querySelectorAll('button,[role="button"],a,[class*="button" i],[class*="Button"]');
  var best=null,bestScore=0,cands=[];
  for(var i=0;i<els.length;i++){
    var el=els[i];
    var txt=norm(el.textContent||el.getAttribute('aria-label')||'');
    if(!txt) continue;
    if(cands.length<20) cands.push(txt);
    var sc=0;
    if(txt===want) sc=100;
    else if(txt.indexOf(want)===0) sc=45;
    else if(txt.indexOf(want)>=0) sc=30;
    if(sc>=30 && sc>bestScore){ bestScore=sc; best=el; }
  }
  if(!best) return {ok:false, matched:false, candidates:cands};
  if(best.scrollIntoView) best.scrollIntoView();
  best.click();
  return {ok:true, clicked:want, score:bestScore};
})()
`;
}

function cdpEvaluate(wsUrl, expression, timeoutMs) {
  return new Promise((resolve, reject) => {
    let ws;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { ws && ws.close(); } catch { /* ignore */ }
      reject(new Error('CDP evaluate timed out after ' + timeoutMs + 'ms'));
    }, timeoutMs);
    const done = (err, val) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws && ws.close(); } catch { /* ignore */ }
      if (err) reject(err); else resolve(val);
    };
    try {
      ws = new WebSocket(wsUrl);
    } catch (e) {
      clearTimeout(timer);
      reject(e);
      return;
    }
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({
        id: 1,
        method: 'Runtime.evaluate',
        params: { expression, returnByValue: true, awaitPromise: true },
      }));
    });
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(String(ev.data)); } catch { return; }
      if (msg.id !== 1) return;
      if (msg.error) return done(new Error(msg.error.message || 'CDP error'));
      if (msg.result && msg.result.exceptionDetails) {
        return done(new Error('page exception: ' + JSON.stringify(msg.result.exceptionDetails)));
      }
      done(null, msg.result && msg.result.result ? msg.result.result.value : undefined);
    });
    ws.addEventListener('error', () => done(new Error('CDP socket error')));
  });
}

async function cdpApprove(label) {
  let targets;
  try {
    targets = await cdpListTargets();
  } catch (e) {
    return { ok: false, error: 'CDP not reachable at ' + CDP_HOST + ':' + CDP_PORT +
      ' — is Bionic running with --remote-debugging-port=' + CDP_PORT + '? (' + (e.message || e) + ')' };
  }
  const page = pickBionicPage(targets);
  if (!page) {
    return { ok: false, error: 'No Bionic page found in CDP targets — is the desktop app open on the session that needs approval?' };
  }
  const target = { title: page.title, url: page.url };
  try {
    const value = await cdpEvaluate(page.webSocketDebuggerUrl, cdpClickExpression(label), CDP_TIMEOUT_MS);
    return { ok: !!(value && value.ok), value, target };
  } catch (e) {
    return { ok: false, error: 'CDP evaluate failed: ' + (e.message || e), target };
  }
}

export {
  CDP_HOST, CDP_PORT, CDP_TIMEOUT_MS,
  readBody, cdpListTargets, pickBionicPage,
  cdpClickExpression, cdpEvaluate, cdpApprove,
};
