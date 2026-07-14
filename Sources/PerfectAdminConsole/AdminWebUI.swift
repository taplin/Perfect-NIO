//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminWebUI — self-contained HTML/CSS/JS for the admin console browser UI.
// No external resources; no CDN; all assets inline.
// Dark/light mode via prefers-color-scheme.

import Foundation
import PerfectNIO

enum AdminWebUI {

    /// Returns the complete HTML page as an HTTPOutput, injecting the token file
    /// path into the JavaScript so the auth-gate form can display it.
    static func response(tokenFilePath: String) -> HTTPOutput {
        // JSON-encode the path so special characters can't break the JS string literal.
        let jsonPath: String
        if let data = try? JSONEncoder().encode(tokenFilePath),
           let s = String(data: data, encoding: .utf8) {
            jsonPath = s
        } else {
            jsonPath = "\"\""
        }
        let html = pageTemplate.replacingOccurrences(of: "{{TOKEN_PATH_JSON}}", with: jsonPath)
        return BytesOutput(
            head: HTTPHead(status: .ok, headers: HTTPHeaders([
                ("Content-Type", "text/html; charset=utf-8"),
                ("Cache-Control", "no-store"),
            ])),
            body: Array(html.utf8)
        )
    }

    // MARK: - Page template
    // Uses #"..."# raw string so JS backslashes and ${} are not interpreted by Swift.
    // The sole server-side substitution is {{TOKEN_PATH_JSON}} (replaced above).

    private static let pageTemplate = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Perfect Admin Console</title>
<style>
:root {
  --bg:#f2f2f7;--card:#fff;--text:#1c1c1e;--muted:#6c6c70;
  --border:#d1d1d6;--accent:#007aff;--ok:#34c759;--err:#ff3b30;
  --mono:'SF Mono','Menlo','Monaco','Courier New',monospace;
}
@media(prefers-color-scheme:dark){
  :root{--bg:#1c1c1e;--card:#2c2c2e;--text:#f2f2f7;--muted:#98989d;--border:#3a3a3c;--accent:#0a84ff;--ok:#30d158;--err:#ff453a;}
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:14px;line-height:1.5;min-height:100vh}
a{color:var(--accent)}
/* ---- auth gate ---- */
#auth-gate{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;gap:14px;padding:24px}
#auth-gate h1{font-size:22px;font-weight:700}
#auth-gate p{color:var(--muted);text-align:center;max-width:340px;font-size:13px}
code{font-family:var(--mono);font-size:12px;background:var(--border);padding:2px 6px;border-radius:4px}
#token-input{width:320px;max-width:100%;padding:10px 14px;border:1px solid var(--border);border-radius:8px;background:var(--card);color:var(--text);font-family:var(--mono);font-size:13px;outline:none}
#token-input:focus{border-color:var(--accent)}
#connect-btn{padding:10px 28px;background:var(--accent);color:#fff;border:none;border-radius:8px;cursor:pointer;font-size:14px;font-weight:600}
#connect-btn:hover{opacity:.88}
#auth-err{color:var(--err);font-size:13px;display:none}
/* ---- dashboard ---- */
#dashboard{display:none}
header{padding:14px 20px;border-bottom:1px solid var(--border);background:var(--card);display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:10}
header h1{font-size:15px;font-weight:600}
.dot{width:8px;height:8px;border-radius:50%;background:var(--ok);display:inline-block;margin-right:6px}
#refresh-badge{font-size:12px;color:var(--muted)}
main{padding:20px;max-width:980px;margin:0 auto}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px;margin-bottom:14px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:16px}
.card h2{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin-bottom:12px}
.row{display:flex;justify-content:space-between;align-items:baseline;padding:5px 0;border-bottom:1px solid var(--border);gap:8px}
.row:last-child{border-bottom:none}
.rl{color:var(--muted);flex-shrink:0}
.rv{font-weight:500;text-align:right;word-break:break-all}
.tag{display:inline-block;padding:2px 8px;border-radius:4px;background:var(--border);font-family:var(--mono);font-size:11px;margin:2px}
/* ---- log tail ---- */
#log-card{margin-top:0}
.log-box{background:#111;color:#0f0;font-family:var(--mono);font-size:12px;line-height:1.6;padding:12px;border-radius:6px;height:220px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
@media(prefers-color-scheme:dark){.log-box{background:#0a0a0a}}
.log-footer{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);margin-top:8px}
/* ---- delegate sections ---- */
#delegate-cards{margin-top:14px;display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px}
</style>
</head>
<body>

<!-- ==================== AUTH GATE ==================== -->
<div id="auth-gate">
  <h1>Perfect Admin Console</h1>
  <p>Enter the bearer token from<br><code id="path-hint"></code></p>
  <input id="token-input" type="password" placeholder="paste token here" autocomplete="off" spellcheck="false">
  <button id="connect-btn" onclick="connect()">Connect</button>
  <span id="auth-err">Invalid token — check the file and try again.</span>
</div>

<!-- ==================== DASHBOARD ==================== -->
<div id="dashboard">
  <header>
    <h1><span class="dot"></span>Perfect Admin Console</h1>
    <span id="refresh-badge">connecting…</span>
  </header>
  <main>
    <div class="grid">
      <div class="card"><h2>Server Status</h2><div id="status-rows"><div class="row"><span class="rl">Loading…</span></div></div></div>
      <div class="card"><h2>TLS Domains</h2><div id="tls-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
      <div class="card"><h2>ACME Challenges</h2><div id="acme-rows"><div class="row"><span class="rl">Loading…</span></div></div></div>
      <div class="card"><h2>Routes</h2><div id="routes-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
    </div>
    <div class="card" id="log-card">
      <h2>Log Tail <span id="log-meta" style="font-weight:400;text-transform:none;letter-spacing:0;color:var(--muted)"></span></h2>
      <div class="log-box" id="log-box">Loading…</div>
      <div class="log-footer">
        <span id="log-count-label"></span>
        <span id="next-refresh">…</span>
      </div>
    </div>
    <div id="delegate-cards"></div>
  </main>
</div>

<script>
'use strict';
const KEY = 'perfectAdminToken';
let token = sessionStorage.getItem(KEY) || '';
let refreshIntervalId = null;
let countdown = 5;

// Inject server-side token path hint
document.getElementById('path-hint').textContent = {{TOKEN_PATH_JSON}};

function hdr() { return { 'Authorization': 'Bearer ' + token }; }

function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function row(label, value) {
  return '<div class="row"><span class="rl">' + esc(label) + '</span><span class="rv">' + esc(value) + '</span></div>';
}

function fmtUptime(s) {
  if (s == null || s <= 0) return '—';
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return (d > 0 ? d + 'd ' : '') + (h > 0 ? h + 'h ' : '') + m + 'm';
}

async function api(path) {
  const r = await fetch(path, { headers: hdr() });
  if (r.status === 401) { logout(); throw new Error('401'); }
  if (!r.ok) throw new Error(r.statusText);
  return r.json();
}

async function refresh() {
  try {
    const [status, tls, acme, logs, routes] = await Promise.all([
      api('/api/status'), api('/api/tls'), api('/api/acme'),
      api('/api/logs?count=100'), api('/api/routes'),
    ]);
    renderStatus(status);
    renderTLS(tls);
    renderACME(acme);
    renderLogs(logs);
    renderRoutes(routes);
    if (status.additionalSections && status.additionalSections.length)
      renderDelegate(status.additionalSections);
    document.getElementById('refresh-badge').textContent =
      'updated ' + new Date().toLocaleTimeString();
  } catch(e) {
    if (e.message === '401') return;
    document.getElementById('refresh-badge').textContent = 'error: ' + e.message;
  }
}

function renderStatus(s) {
  let h = '';
  h += row('Admin port', s.adminPort);
  if (s.serverPort) h += row('Server port', s.serverPort);
  if (s.uptimeSeconds != null) h += row('Uptime', fmtUptime(s.uptimeSeconds));
  const tlsLabel = s.tlsDomainCount > 0
    ? s.tlsDomainCount + ' domain' + (s.tlsDomainCount !== 1 ? 's' : '') + (s.tlsHasDefault ? ' + default' : '')
    : (s.tlsHasDefault ? 'Default only' : 'Disabled');
  h += row('TLS', tlsLabel);
  h += row('ACME pending', s.acmePendingChallenges === 0 ? '✓ none' : String(s.acmePendingChallenges));
  document.getElementById('status-rows').innerHTML = h;
}

function renderTLS(t) {
  if (!t.domains.length && !t.hasDefault) {
    document.getElementById('tls-content').innerHTML =
      '<div class="row"><span class="rl" style="color:var(--muted)">No TLS configured</span></div>';
    return;
  }
  let h = t.domains.map(d => '<span class="tag">' + esc(d) + '</span>').join('');
  if (t.hasDefault) h += '<span class="tag" style="opacity:.55">+ default</span>';
  document.getElementById('tls-content').innerHTML = h || '<span style="color:var(--muted);font-size:13px">none</span>';
}

function renderACME(a) {
  document.getElementById('acme-rows').innerHTML =
    row('Pending challenges', a.pendingChallenges === 0 ? '✓ none' : String(a.pendingChallenges));
}

function renderLogs(l) {
  const box = document.getElementById('log-box');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  box.textContent = l.lines.length ? l.lines.join('\n') : '(no log lines captured yet)';
  if (atBottom) box.scrollTop = box.scrollHeight;
  document.getElementById('log-count-label').textContent =
    'showing ' + l.lines.length + ' of ' + l.totalCaptured + ' captured';
}

function renderRoutes(r) {
  if (!r.routes.length) {
    document.getElementById('routes-content').innerHTML =
      '<div class="row"><span class="rl" style="color:var(--muted)">No routes from delegate</span></div>';
    return;
  }
  document.getElementById('routes-content').innerHTML =
    r.routes.map(u => '<span class="tag">' + esc(u) + '</span>').join('');
}

function renderDelegate(sections) {
  const el = document.getElementById('delegate-cards');
  el.innerHTML = sections.map(s => {
    const rows = Object.entries(s.items).map(([k,v]) => row(k, v)).join('');
    return '<div class="card"><h2>' + esc(s.title) + '</h2>' + rows + '</div>';
  }).join('');
}

async function connect() {
  const input = document.getElementById('token-input').value.trim();
  if (!input) return;
  token = input;
  document.getElementById('auth-err').style.display = 'none';
  try {
    await api('/api/status');
    sessionStorage.setItem(KEY, token);
    showDashboard();
  } catch(e) {
    if (e.message === '401') {
      document.getElementById('auth-err').style.display = 'block';
      token = '';
    }
  }
}

function logout() {
  sessionStorage.removeItem(KEY);
  token = '';
  clearInterval(refreshIntervalId);
  document.getElementById('dashboard').style.display = 'none';
  document.getElementById('auth-gate').style.display = 'flex';
}

function showDashboard() {
  document.getElementById('auth-gate').style.display = 'none';
  document.getElementById('dashboard').style.display = 'block';
  refresh();
  clearInterval(refreshIntervalId);
  countdown = 5;
  refreshIntervalId = setInterval(() => {
    countdown--;
    document.getElementById('next-refresh').textContent = 'refresh in ' + countdown + 's';
    if (countdown <= 0) { countdown = 5; refresh(); }
  }, 1000);
}

// Enter key in token field
document.getElementById('token-input').addEventListener('keydown', e => {
  if (e.key === 'Enter') connect();
});

// Auto-connect if a token is already in sessionStorage
if (token) showDashboard();
</script>
</body>
</html>
"""#
}
