import {createServer} from 'node:http';
import {readFileSync, renameSync, writeFileSync} from 'node:fs';
import {connect as connectTCP} from 'node:net';
import {timingSafeEqual} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {dirname, join} from 'node:path';
import {WebSocket, WebSocketServer} from 'ws';
import {applyThreadPolicy, COMPACTION_SCOPE, DEFAULT_COMPACTION_THRESHOLD} from './policy.mjs';

const MAX_FRAME_BYTES = 32 * 1024 * 1024;
const MAX_QUEUED_BYTES = 32 * 1024 * 1024;

function credential(request) {
  const header = request.headers.authorization || '';
  if (header.startsWith('Bearer ')) return header.slice(7);
  try { return new URL(request.url, 'http://localhost').searchParams.get('token') || ''; }
  catch { return ''; }
}

function authorized(request, tokenFile) {
  const supplied = Buffer.from(credential(request));
  const expected = Buffer.from(readFileSync(tokenFile, 'utf8').trim());
  return expected.length > 0 && supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

function upstreamAvailable(host, port) {
  return new Promise(resolve => {
    const socket = connectTCP({host, port});
    const finish = value => { socket.destroy(); resolve(value); };
    socket.setTimeout(800, () => finish(false));
    socket.once('connect', () => finish(true));
    socket.once('error', () => finish(false));
  });
}

function rootRouteUsesGateway() {
  try {
    const config = readFileSync('/etc/nginx/sites-enabled/codex-auth', 'utf8');
    return /location\s+\/\s*\{\s*proxy_pass\s+http:\/\/127\.0\.0\.1:4520;/.test(config);
  } catch { return false; }
}

export function createGateway({tokenFile, upstream = 'ws://127.0.0.1:4500', host = '127.0.0.1', port = 4520,
  compactionEnabled = false, compactionThresholdTokens = DEFAULT_COMPACTION_THRESHOLD,
  compactionStateFile = null, compactionSettingsFile = compactionStateFile ? join(dirname(compactionStateFile), 'settings.json') : null,
  handoffThreadId = '', handoffFile = null}) {
  if (!tokenFile) throw new Error('Token file is required');
  readFileSync(tokenFile); // Refuse to start without the existing app-server credential.
  const handoffText = handoffFile ? readFileSync(handoffFile, 'utf8').trim() : '';
  if (handoffText.length > 16_000) throw new Error('Handoff is too large');
  const target = new URL(upstream);
  if (target.protocol !== 'ws:' || !['127.0.0.1', 'localhost'].includes(target.hostname)) {
    throw new Error('The app-server upstream must be loopback WebSocket');
  }
  const validThreshold = value => Number.isSafeInteger(value) && value >= 20_000 && value <= 1_000_000;
  if (!validThreshold(compactionThresholdTokens)) {
    throw new Error('Invalid compaction threshold');
  }
  if (compactionSettingsFile) {
    try {
      const saved = JSON.parse(readFileSync(compactionSettingsFile, 'utf8'));
      if (!validThreshold(saved.thresholdTokens)) throw new Error('Invalid saved compaction threshold');
      compactionThresholdTokens = saved.thresholdTokens;
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  const stats = {startedAt: new Date().toISOString(), activeConnections: 0,
    proxiedConnectionsSinceStart: 0, completedTurnsSinceStart: 0, failedTurnsSinceStart: 0,
    policyApplicationsSinceStart: 0, lastTurnAt: null};
  let compactionActivity = {observedSince: stats.startedAt, completed: 0, lastCompletedAt: null,
    byThread: {}, recentItems: []};
  if (compactionStateFile) {
    try {
      const saved = JSON.parse(readFileSync(compactionStateFile, 'utf8'));
      if (typeof saved.observedSince === 'string' && Number.isSafeInteger(saved.completed)
          && saved.completed >= 0 && saved.byThread && typeof saved.byThread === 'object') {
        compactionActivity = saved;
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  const recordCompaction = (threadId, itemId) => {
    if (!threadId || !itemId) return;
    const key = `${threadId}:${itemId}`;
    if (compactionActivity.recentItems?.includes(key)) return;
    compactionActivity.recentItems = [...(compactionActivity.recentItems || []), key].slice(-256);
    const at = new Date().toISOString();
    compactionActivity.completed++;
    compactionActivity.lastCompletedAt = at;
    const prior = compactionActivity.byThread[threadId];
    compactionActivity.byThread[threadId] = {completed: (prior?.completed || 0) + 1, lastCompletedAt: at};
    if (compactionStateFile) {
      const temporary = compactionStateFile + '.tmp';
      writeFileSync(temporary, JSON.stringify(compactionActivity), {mode: 0o600});
      renameSync(temporary, compactionStateFile);
    }
  };
  const prepare = (data, isBinary) => {
    const outgoing = applyThreadPolicy(data, isBinary,
      {enabled: compactionEnabled, thresholdTokens: compactionThresholdTokens,
        handoffThreadId, handoffText});
    if (outgoing !== data) stats.policyApplicationsSinceStart++;
    return outgoing;
  };
  const webSockets = new WebSocketServer({noServer: true, maxPayload: MAX_FRAME_BYTES, perMessageDeflate: false});
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://localhost');
    const path = url.pathname;
    if (path !== '/gateway/health' || !['GET', 'POST'].includes(request.method)) {
      response.writeHead(404).end(); return;
    }
    if (!authorized(request, tokenFile)) { response.writeHead(401).end(); return; }
    if (request.method === 'POST') {
      if (!compactionSettingsFile || !compactionEnabled) { response.writeHead(503).end(); return; }
      let body = '';
      try {
        for await (const chunk of request) {
          body += chunk.toString('utf8');
          if (Buffer.byteLength(body) > 1024) { response.writeHead(413).end(); return; }
        }
        const update = JSON.parse(body);
        if (!update || typeof update !== 'object' || Array.isArray(update) ||
            Object.keys(update).sort().join(',') !== 'expectedThresholdTokens,thresholdTokens' ||
            !validThreshold(update.thresholdTokens) || !validThreshold(update.expectedThresholdTokens)) {
          response.writeHead(400).end(); return;
        }
        if (update.expectedThresholdTokens !== compactionThresholdTokens) { response.writeHead(409).end(); return; }
        const temporary = compactionSettingsFile + '.tmp';
        try {
          writeFileSync(temporary, JSON.stringify({thresholdTokens: update.thresholdTokens}), {mode: 0o600});
          renameSync(temporary, compactionSettingsFile);
        } catch { response.writeHead(503).end(); return; }
        compactionThresholdTokens = update.thresholdTokens;
        response.writeHead(200, {'content-type': 'application/json', 'cache-control': 'no-store'});
        response.end(JSON.stringify({thresholdTokens: compactionThresholdTokens, applies: 'next-thread-resume'}));
      } catch { if (!response.headersSent) response.writeHead(400).end(); }
      return;
    }
    const connected = await upstreamAvailable(target.hostname, Number(target.port || 80));
    const threadId = url.searchParams.get('threadId');
    const threadActivity = threadId ? compactionActivity.byThread[threadId] : compactionActivity;
    response.writeHead(connected ? 200 : 503, {'content-type': 'application/json', 'cache-control': 'no-store'});
    response.end(JSON.stringify({service: 'vesper-gateway', mode: compactionEnabled ? 'native-compaction' : 'transparent',
      upstream: connected ? 'reachable' : 'unavailable', routeActive: rootRouteUsesGateway(),
      compaction: {enabled: compactionEnabled, thresholdTokens: compactionThresholdTokens, scope: COMPACTION_SCOPE,
        editable: Boolean(compactionEnabled && compactionSettingsFile)},
      handoffActive: Boolean(handoffThreadId && handoffText),
      compactionActivity: {observedSince: compactionActivity.observedSince,
        completed: threadActivity?.completed || 0, lastCompletedAt: threadActivity?.lastCompletedAt || null,
        scope: threadId ? 'thread' : 'all'},
      ...stats}));
  });
  server.on('upgrade', (request, socket, head) => {
    const path = new URL(request.url, 'http://localhost').pathname;
    if (path !== '/' && path !== '/gateway') {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n'); return;
    }
    if (!authorized(request, tokenFile)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return;
    }
    webSockets.handleUpgrade(request, socket, head, client => {
      stats.activeConnections++;
      stats.proxiedConnectionsSinceStart++;
      let upstreamSocket;
      let closed = false;
      let queuedBytes = 0;
      const waiting = [];
      const finish = (code = 1000) => {
        if (closed) return;
        closed = true;
        stats.activeConnections--;
        if (client.readyState === WebSocket.OPEN) client.close(code);
        else client.terminate();
        if (upstreamSocket?.readyState === WebSocket.OPEN) upstreamSocket.close(code);
        else upstreamSocket?.terminate();
      };
      const forward = (destination, data, isBinary) => {
        if (destination.bufferedAmount + data.length > MAX_QUEUED_BYTES) { finish(1013); return; }
        destination.send(data, {binary: isBinary}, error => { if (error) finish(1011); });
      };
      try {
        upstreamSocket = new WebSocket(upstream, {
          headers: {Authorization: `Bearer ${readFileSync(tokenFile, 'utf8').trim()}`},
          maxPayload: MAX_FRAME_BYTES, perMessageDeflate: false, handshakeTimeout: 8000
        });
      } catch { finish(1011); return; }
      upstreamSocket.on('open', () => {
        for (const {data, isBinary} of waiting) forward(upstreamSocket, prepare(data, isBinary), isBinary);
        waiting.length = 0;
        queuedBytes = 0;
      });
      client.on('message', (data, isBinary) => {
        if (upstreamSocket.readyState === WebSocket.OPEN) forward(upstreamSocket, prepare(data, isBinary), isBinary);
        else if (upstreamSocket.readyState === WebSocket.CONNECTING) {
          queuedBytes += data.length;
          if (queuedBytes > MAX_QUEUED_BYTES) finish(1013);
          else waiting.push({data, isBinary});
        }
      });
      upstreamSocket.on('message', (data, isBinary) => {
        // Only inspect bounded notification metadata. Never retain prompts, tool output or frames.
        if (!isBinary && data.length < 32768) {
          try {
            const packet = JSON.parse(data.toString());
            if (packet.method === 'turn/completed') {
              stats.lastTurnAt = new Date().toISOString();
              if (packet.params?.turn?.status === 'completed') stats.completedTurnsSinceStart++;
              else stats.failedTurnsSinceStart++;
            } else if (packet.method === 'item/completed' && packet.params?.item?.type === 'contextCompaction') {
              recordCompaction(packet.params?.threadId, packet.params?.item?.id);
            }
          } catch { /* Opaque app-server frame: forward unchanged. */ }
        }
        if (client.readyState === WebSocket.OPEN) forward(client, data, isBinary);
      });
      client.on('close', () => finish());
      upstreamSocket.on('close', () => finish());
      client.on('error', () => finish(1011));
      upstreamSocket.on('error', () => finish(1011));
    });
  });
  return {server, webSockets, stats, listen: () => new Promise(resolve => server.listen(port, host, resolve)),
    close: () => new Promise(resolve => { for (const client of webSockets.clients) client.terminate(); server.close(resolve); })};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const gateway = createGateway({tokenFile: process.env.VESPER_GATEWAY_TOKEN_FILE,
    upstream: process.env.VESPER_GATEWAY_UPSTREAM || 'ws://127.0.0.1:4500',
    port: Number(process.env.VESPER_GATEWAY_PORT || 4520),
    compactionEnabled: process.env.VESPER_GATEWAY_COMPACTION === '1',
    compactionStateFile: process.env.VESPER_GATEWAY_COMPACTION_STATE_FILE || null,
    compactionThresholdTokens: Number(process.env.VESPER_GATEWAY_COMPACTION_THRESHOLD || DEFAULT_COMPACTION_THRESHOLD),
    handoffThreadId: process.env.VESPER_GATEWAY_HANDOFF_THREAD_ID || '',
    handoffFile: process.env.VESPER_GATEWAY_HANDOFF_FILE || null});
  await gateway.listen();
  console.log('Vesper gateway listening on loopback');
}
