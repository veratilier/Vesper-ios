// Inject only the installed Codex app-server's native, in-place compaction setting.
// All other protocol frames and thread identity stay unchanged.
export const DEFAULT_COMPACTION_THRESHOLD = 240_000;
export const COMPACTION_SCOPE = 'total';

export function applyThreadPolicy(data, isBinary, {enabled = false, thresholdTokens = DEFAULT_COMPACTION_THRESHOLD,
  handoffThreadId = '', handoffText = ''} = {}) {
  if (!enabled || isBinary || data.length > 8 * 1024 * 1024) return data;
  let packet;
  try { packet = JSON.parse(data.toString()); } catch { return data; }
  if (packet?.method !== 'thread/start' && packet?.method !== 'thread/resume') return data;
  if (!packet.params || typeof packet.params !== 'object' || Array.isArray(packet.params)) return data;
  const config = packet.params.config;
  if (config != null && (typeof config !== 'object' || Array.isArray(config))) return data;
  packet.params.config = {
    ...(config || {}),
    model_auto_compact_token_limit: thresholdTokens,
    model_auto_compact_token_limit_scope: COMPACTION_SCOPE
  };
  // A short handoff can bridge a same-thread context-window reset. Only the
  // named existing thread receives it, and only when the client supplies its
  // complete normal instructions. This never changes other conversations.
  if (packet.method === 'thread/resume' && packet.params.threadId === handoffThreadId &&
      handoffText && typeof packet.params.developerInstructions === 'string' &&
      !packet.params.developerInstructions.includes(handoffText)) {
    packet.params.developerInstructions += '\n\n' + handoffText;
  }
  return Buffer.from(JSON.stringify(packet));
}
