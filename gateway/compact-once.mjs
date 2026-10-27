// Operator-only, one-shot native Codex compaction for an already idle thread.
// Run on the VPS. The gateway records the resulting contextCompaction item.
import {readFileSync} from 'node:fs';
import {WebSocket} from 'ws';

const threadId = process.argv[2];
const applyOnly = process.argv[3] === '--apply-only';
const tokenFile = process.env.VESPER_GATEWAY_TOKEN_FILE;
if (!/^[0-9a-f-]{36}$/.test(threadId || '') || !tokenFile) {
  throw new Error('Usage: VESPER_GATEWAY_TOKEN_FILE=... node compact-once.mjs <thread-id>');
}
const token = readFileSync(tokenFile, 'utf8').trim();
const socket = new WebSocket('ws://127.0.0.1:4520/', {headers: {Authorization: `Bearer ${token}`}});
const pending = new Map();
let compacted = false;
let turnCompleted = false;
let compactStarted = false;
const finish = () => {
  if (compacted && turnCompleted) {
    console.log('Compaction item and turn completed.');
    socket.close();
  }
};
socket.on('message', data => {
  const packet = JSON.parse(data.toString());
  if (packet.id != null && pending.has(packet.id)) {
    const {resolve, reject} = pending.get(packet.id);
    pending.delete(packet.id);
    packet.error ? reject(new Error(packet.error.message || 'RPC failed')) : resolve(packet.result);
  }
  if (packet.params?.threadId !== threadId) return;
  if (packet.method === 'item/started' && packet.params.item?.type === 'contextCompaction') {
    compactStarted = true;
    console.log('Compaction started.');
  }
  if (packet.method === 'item/completed' && packet.params.item?.type === 'contextCompaction') {
    compacted = true;
    console.log('Compaction completed.');
    finish();
  }
  if (packet.method === 'turn/completed' && compactStarted) {
    turnCompleted = true;
    console.log(`Turn status: ${packet.params.turn?.status || 'unknown'}`);
    finish();
  }
});
socket.on('error', error => { console.error(error.message); process.exitCode = 1; });
const timer = setTimeout(() => {
  console.error('Timed out waiting for the compaction item and turn.');
  process.exitCode = 1;
  socket.terminate();
}, 240_000);
socket.on('close', () => clearTimeout(timer));
await new Promise((resolve, reject) => {
  socket.once('open', resolve);
  socket.once('error', reject);
});
let nextId = 0;
function request(method, params) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });
}
await request('initialize', {clientInfo: {name: 'vesper_gateway_maintenance', title: 'Vesper', version: '0.1.0'},
  capabilities: {experimentalApi: true, requestAttestation: false}});
socket.send(JSON.stringify({method: 'initialized'}));
const resumed = await request('thread/resume', {threadId, config: {}, excludeTurns: true});
if (resumed.thread?.id !== threadId) throw new Error('Server resumed a different thread.');
console.log('Existing thread resumed with gateway policy.');
if (applyOnly) {
  console.log('Policy applied without a model turn.');
  socket.close();
} else {
  await request('thread/compact/start', {threadId});
  console.log('Native compaction requested.');
}
await new Promise(resolve => socket.once('close', resolve));
