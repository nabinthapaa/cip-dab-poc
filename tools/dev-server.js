#!/usr/bin/env node
/* =============================================================================
 * DAB-compatible dev server - no Docker, no SQL Server.
 *
 * Serves the portal in LIVE mode and answers /api/<view> over real HTTP with
 * the same behaviour as gateway + DAB: subscription keys, 401/403/404, JSON
 * shaped {"value":[...]}, row-level isolation per client. The database is the
 * in-memory emulator (portal/js/emulator.js), so this is for front-end work
 * and demos; `docker compose up` runs the real SQL Server + DAB stack.
 *
 *   node tools/dev-server.js            -> http://localhost:8080
 *   PORT=9000 node tools/dev-server.js
 * ============================================================================= */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PORTAL = path.join(ROOT, 'portal');
const { Emulator, KEYS } = require(path.join(PORTAL, 'js', 'emulator.js'));
const seed = JSON.parse(fs.readFileSync(path.join(PORTAL, 'data', 'seed.json'), 'utf8'));
const emu = new Emulator(seed);
const TICK = Number(process.env.SIM_TICK_SECONDS || 3) * 1000;
setInterval(() => emu.step(), TICK);
emu.on((ev) => console.log(`${new Date().toISOString().slice(11, 19)} ${ev.source_system.padEnd(16)} ${ev.event_type.padEnd(18)} ${ev.entity_ref || ''} ${ev.detail || ''}`));

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.css': 'text/css' };

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const started = Date.now();
  if (url.pathname === '/config.js') {
    res.writeHead(200, { 'content-type': 'application/javascript', 'cache-control': 'no-cache' });
    return res.end("window.CIP_CONFIG = { mode: 'live', base: '' };\n");
  }
  if (url.pathname.startsWith('/api/') || url.pathname === '/api') {
    const r = emu.request(req.method, req.url, req.headers);
    res.writeHead(r.status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(r.body));
    const key = req.headers['ocp-apim-subscription-key'];
    const client = key && KEYS[key];
    console.log(JSON.stringify({ time: new Date().toISOString(), client: client ? client.client_code : '', method: req.method, uri: req.url, status: r.status, ms: Date.now() - started }));
    return;
  }
  let file = path.normalize(path.join(PORTAL, decodeURIComponent(url.pathname)));
  if (!file.startsWith(PORTAL)) { res.writeHead(403); return res.end(); }
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
  if (!fs.existsSync(file)) { res.writeHead(404); return res.end('not found'); }
  res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-cache' });
  fs.createReadStream(file).pipe(res);
});

const PORT = Number(process.env.PORT || 8080);
server.listen(PORT, () => console.log(`CIP dev server (emulated database) on http://localhost:${PORT}`));
