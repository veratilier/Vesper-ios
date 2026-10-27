// Reset one idle Codex thread's active context, retaining its thread ID.
// An operator must first back up its rollout and arrange a short handoff.
import {readFileSync} from 'node:fs';
import {WebSocket} from 'ws';

const threadId = process.argv[2];
const tokenFile = process.env.VESPER_GATEWAY_TOKEN_FILE;
if (!/^[0-9a-f-]{36}$/.test(threadId || '') || !tokenFile) {
  throw new Error('Usage: VESPER_GATEWAY_TOKEN_FILE=... node window-reset.mjs <thread-id>');
}
const token = readFileSync(tokenFile, 'utf8').trim();
const socket = new WebSocket('ws://127.0.0.1:4520/', {headers: {Authorization: `Bearer ${token}`}});
const pending = new Map();
let nextId = 0;
let completedItem = false;
let completedTurn = false;
let turnStatus = '';
let resolveDone;
const done = new Promise(resolve => {resolveDone = resolve;});
const checkDone = () => {if (completedItem && completedTurn) resolveDone();};
socket.on('message', data => {
  const packet = JSON.parse(data.toString());
  if (packet.id != null && pending.has(packet.id)) {
    const {resolve, reject} = pending.get(packet.id);
    pending.delete(packet.id);
    packet.error ? reject(new Error(packet.error.message || 'RPC error')) : resolve(packet.result);
  }
  if (packet.params?.threadId !== threadId) return;
  if (packet.method === 'item/completed' && packet.params.item?.type === 'contextCompaction') {
    completedItem = true; checkDone();
  }
  if (packet.method === 'turn/completed') {
    turnStatus = packet.params.turn?.status || '';
    completedTurn = true; checkDone();
  }
});
function request(method, params) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });
}
await new Promise((resolve, reject) => {socket.once('open', resolve); socket.once('error', reject);});
try {
  await request('initialize', {clientInfo: {name: 'vesper_window_reset', title: 'Vesper', version: '0.1.0'},
    capabilities: {experimentalApi: true, requestAttestation: false}});
  socket.send(JSON.stringify({method: 'initialized'}));
  const resumed = await request('thread/resume', {threadId, config: {'features.token_budget': true}, excludeTurns: true});
  if (resumed.thread?.id !== threadId) throw new Error('Resumed the wrong thread');
  await request('thread/compact/start', {threadId});
  let timeout;
  try {
    await Promise.race([done, new Promise((_, reject) => {
      timeout = setTimeout(() => reject(new Error('Reset timed out')), 90_000);
    })]);
  } finally {
    clearTimeout(timeout);
  }
  if (turnStatus !== 'completed') throw new Error(`Reset turn ended with ${turnStatus}`);
  const restored = await request('thread/resume', {threadId, config: {'features.token_budget': false}, excludeTurns: true});
  if (restored.thread?.id !== threadId) throw new Error('Post-reset resume changed thread ID');
  console.log(JSON.stringify({sameThread: true, resetCompleted: true, tokenBudgetDisabled: true}));
} finally {
  socket.close();
}
