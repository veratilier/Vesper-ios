// One-shot isolated test of Codex's same-thread token-budget context reset.
// It never touches the Vesper/Ash thread. Use the loopback gateway token file.
import {readFileSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {WebSocket} from 'ws';

const tokenFile = process.env.VESPER_GATEWAY_TOKEN_FILE;
if (!tokenFile) throw new Error('Set VESPER_GATEWAY_TOKEN_FILE');
const token = readFileSync(tokenFile, 'utf8').trim();
const socket = new WebSocket('ws://127.0.0.1:4520/', {headers: {Authorization: `Bearer ${token}`}});
const pending = new Map();
const events = [];
const waiters = [];
let nextId = 0;
let latestUsage = null;
const marker = randomBytes(8).toString('hex');

function waitFor(predicate, timeout = 90_000) {
  const index = events.findIndex(predicate);
  if (index !== -1) return Promise.resolve(events.splice(index, 1)[0]);
  return new Promise((resolve, reject) => {
    const waiter = {predicate, resolve: packet => {clearTimeout(timer); resolve(packet);}};
    const timer = setTimeout(() => {
      const index = waiters.indexOf(waiter);
      if (index !== -1) waiters.splice(index, 1);
      reject(new Error('Timed out waiting for app-server event'));
    }, timeout);
    waiters.push(waiter);
  });
}
function request(method, params) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });
}
socket.on('message', data => {
  const packet = JSON.parse(data.toString());
  if (packet.id != null && pending.has(packet.id)) {
    const {resolve, reject} = pending.get(packet.id);
    pending.delete(packet.id);
    packet.error ? reject(new Error(packet.error.message || 'RPC error')) : resolve(packet.result);
  }
  if (packet.method === 'thread/tokenUsage/updated') latestUsage = packet.params?.tokenUsage || packet.params;
  if (!packet.method) return;
  const index = waiters.findIndex(waiter => waiter.predicate(packet));
  if (index !== -1) waiters.splice(index, 1)[0].resolve(packet);
  else events.push(packet);
});
await new Promise((resolve, reject) => {socket.once('open', resolve); socket.once('error', reject);});
try {
  await request('initialize', {clientInfo: {name: 'vesper_window_canary', title: 'Vesper test', version: '0.1.0'},
    capabilities: {experimentalApi: true, requestAttestation: false}});
  socket.send(JSON.stringify({method: 'initialized'}));
  const started = await request('thread/start', {dynamicTools: [],
    config: {'features.token_budget': true}, approvalPolicy: 'never', sandbox: 'danger-full-access',
    developerInstructions: 'For this isolated test, follow the latest user message. Do not call tools.'});
  const threadId = started.thread?.id;
  if (!threadId) throw new Error('No test thread ID');
  const first = await request('turn/start', {threadId, input: [{type: 'text', text: `Reply OK. Test marker: ${marker}`}],
    model: 'gpt-6-luna', effort: 'low', approvalPolicy: 'never', sandboxPolicy: {type: 'dangerFullAccess'}});
  const firstTurnId = first.turn?.id;
  await waitFor(p => p.method === 'turn/completed' && p.params?.turn?.id === firstTurnId);
  const firstUsage = latestUsage?.last || latestUsage?.lastTokenUsage || null;
  const compact = waitFor(p => p.method === 'item/completed' && p.params?.threadId === threadId &&
    p.params?.item?.type === 'contextCompaction');
  await request('thread/compact/start', {threadId});
  await compact;
  await waitFor(p => p.method === 'turn/completed' && p.params?.threadId === threadId && p.params?.turn?.id !== firstTurnId);
  const resumed = await request('thread/resume', {threadId, config: {'features.token_budget': true}, excludeTurns: true});
  if (resumed.thread?.id !== threadId) throw new Error('Context reset changed thread ID');
  const second = await request('turn/start', {threadId, input: [{type: 'text',
    text: `Summary from prior window: the test marker is ${marker}. Reply with the marker only.`}],
    model: 'gpt-6-luna', effort: 'low', approvalPolicy: 'never', sandboxPolicy: {type: 'dangerFullAccess'}});
  const secondTurnId = second.turn?.id;
  await waitFor(p => p.method === 'turn/completed' && p.params?.turn?.id === secondTurnId);
  const secondUsage = latestUsage?.last || latestUsage?.lastTokenUsage || null;
  console.log(JSON.stringify({sameThread: true, resetCompleted: true,
    firstUsage: firstUsage && {inputTokens: firstUsage.inputTokens, cachedInputTokens: firstUsage.cachedInputTokens},
    secondUsage: secondUsage && {inputTokens: secondUsage.inputTokens, cachedInputTokens: secondUsage.cachedInputTokens}}));
} finally {
  socket.close();
}
