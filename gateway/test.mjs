import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {once} from 'node:events';
import {WebSocket, WebSocketServer} from 'ws';
import {createGateway} from './server.mjs';
import {applyThreadPolicy} from './policy.mjs';

test('handoff affects only the selected thread and keeps normal instructions', () => {
  const options = {enabled: true, handoffThreadId: 'ash', handoffText: 'Recent context: no emoji.'};
  const frame = (threadId, developerInstructions) => Buffer.from(JSON.stringify({method: 'thread/resume',
    params: {threadId, developerInstructions, config: {}}}));
  const ash = JSON.parse(applyThreadPolicy(frame('ash', 'Base instructions.'), false, options));
  assert.equal(ash.params.developerInstructions, 'Base instructions.\n\nRecent context: no emoji.');
  const other = JSON.parse(applyThreadPolicy(frame('other', 'Base instructions.'), false, options));
  assert.equal(other.params.developerInstructions, 'Base instructions.');
  const absent = JSON.parse(applyThreadPolicy(frame('ash', undefined), false, options));
  assert.equal(absent.params.developerInstructions, undefined);
});

test('authenticated pass-through preserves frames and reports only live status', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'vesper-gateway-'));
  const tokenFile = join(directory, 'token'); writeFileSync(tokenFile, 'test-secret\n');
  const compactionStateFile = join(directory, 'compactions.json');
  t.after(() => rmSync(directory, {recursive: true, force: true}));
  const upstream = new WebSocketServer({host: '127.0.0.1', port: 0});
  await once(upstream, 'listening');
  t.after(() => upstream.close());
  upstream.on('connection', socket => {
    socket.on('message', (data, binary) => {
      socket.send(data, {binary});
      socket.send(JSON.stringify({method: 'turn/completed', params: {turn: {status: 'completed'}}}));
      if (JSON.parse(data.toString()).method === 'thread/resume') {
        const compacted = JSON.stringify({method: 'item/completed', params: {
          threadId: 'same-thread', item: {type: 'contextCompaction', id: 'compact-1'}}});
        socket.send(compacted);
        socket.send(compacted); // A second subscriber must not double-count the same item.
      }
    });
  });
  const gateway = createGateway({tokenFile, upstream: `ws://127.0.0.1:${upstream.address().port}`,
    port: 0, compactionEnabled: true, compactionStateFile});
  await gateway.listen();
  t.after(() => gateway.close());
  const port = gateway.server.address().port;
  const denied = await fetch(`http://127.0.0.1:${port}/gateway/health`);
  assert.equal(denied.status, 401);
  const client = new WebSocket(`ws://127.0.0.1:${port}/gateway?token=test-secret`);
  await once(client, 'open');
  const received = [];
  const messages = new Promise(resolve => client.on('message', frame => {
    received.push(JSON.parse(frame.toString()));
    if (received.length === 2) resolve();
  }));
  client.send(JSON.stringify({id: '1', method: 'initialize', params: {}}));
  await messages;
  assert.deepEqual(received[0], {id: '1', method: 'initialize', params: {}});
  const rewritten = new Promise(resolve => client.on('message', frame => {
    const packet = JSON.parse(frame.toString());
    if (packet.id === '2') resolve(packet);
  }));
  client.send(JSON.stringify({id: '2', method: 'thread/resume', params: {
    threadId: 'same-thread', config: {compact_prompt: 'preserve continuity'}
  }}));
  const policyFrame = await rewritten;
  assert.equal(policyFrame.params.threadId, 'same-thread');
  assert.equal(policyFrame.params.config.compact_prompt, 'preserve continuity');
  assert.equal(policyFrame.params.config.model_auto_compact_token_limit, 240_000);
  assert.equal(policyFrame.params.config.model_auto_compact_token_limit_scope, 'total');
  const health = await fetch(`http://127.0.0.1:${port}/gateway/health`, {
    headers: {Authorization: 'Bearer test-secret'}
  });
  assert.equal(health.status, 200);
  const status = await health.json();
  assert.equal(status.mode, 'native-compaction');
  assert.equal(status.compaction.enabled, true);
  assert.equal(status.upstream, 'reachable');
  assert.equal(status.activeConnections, 1);
  assert.equal(status.completedTurnsSinceStart, 2);
  assert.equal(status.policyApplicationsSinceStart, 1);
  assert.equal(status.compactionActivity.completed, 1);
  const threadHealth = await fetch(`http://127.0.0.1:${port}/gateway/health?threadId=same-thread`, {
    headers: {Authorization: 'Bearer test-secret'}
  });
  assert.equal((await threadHealth.json()).compactionActivity.completed, 1);
  assert.equal(JSON.parse(readFileSync(compactionStateFile, 'utf8')).completed, 1);
  assert.equal(JSON.stringify(status).includes('test-secret'), false);
  const endpoint = `http://127.0.0.1:${port}/gateway/health`;
  const update = (value, authenticated = true) => fetch(endpoint, {method: 'POST',
    headers: authenticated ? {Authorization: 'Bearer test-secret'} : {}, body: JSON.stringify(value)});
  assert.equal((await update({thresholdTokens: 100_000, expectedThresholdTokens: 240_000}, false)).status, 401);
  assert.equal((await update({thresholdTokens: 10, expectedThresholdTokens: 240_000})).status, 400);
  assert.equal((await update({thresholdTokens: 100_000, expectedThresholdTokens: 200_000})).status, 409);
  assert.equal((await update({thresholdTokens: 100_000, expectedThresholdTokens: 240_000})).status, 200);
  assert.equal(JSON.parse(readFileSync(join(directory, 'settings.json'), 'utf8')).thresholdTokens, 100_000);
  const next = new Promise(resolve => client.on('message', frame => {
    const packet = JSON.parse(frame.toString()); if (packet.id === '3') resolve(packet);
  }));
  client.send(JSON.stringify({id: '3', method: 'thread/resume', params: {threadId: 'same-thread'}}));
  assert.equal((await next).params.config.model_auto_compact_token_limit, 100_000);
  assert.equal((await (await fetch(endpoint, {headers: {Authorization: 'Bearer test-secret'}})).json()).compaction.thresholdTokens, 100_000);
  client.close(); await once(client, 'close');
});

test('saved threshold survives gateway restart and malformed settings are rejected', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'vesper-settings-'));
  t.after(() => rmSync(directory, {recursive: true, force: true}));
  const tokenFile = join(directory, 'token'), compactionStateFile = join(directory, 'state.json');
  writeFileSync(tokenFile, 'test-secret');
  writeFileSync(join(directory, 'settings.json'), JSON.stringify({thresholdTokens: 123_000}));
  const gateway = createGateway({tokenFile, port: 0, compactionEnabled: true, compactionStateFile});
  await gateway.listen();
  const response = await fetch(`http://127.0.0.1:${gateway.server.address().port}/gateway/health`,
    {headers: {Authorization: 'Bearer test-secret'}});
  assert.equal((await response.json()).compaction.thresholdTokens, 123_000);
  await gateway.close();
  writeFileSync(join(directory, 'settings.json'), JSON.stringify({thresholdTokens: 1}));
  assert.throws(() => createGateway({tokenFile, port: 0, compactionEnabled: true, compactionStateFile}), /Invalid saved/);
});
