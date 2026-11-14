import logicModule from "./generated/logic.wasm";

// Pure integer rules shared with the Swift client (Sources/ProtocolModels/Wire.swift `WireRules`),
// built into a tiny import-free Wasm module by Scripts/build-worker-wasm.sh.
export const logic = new WebAssembly.Instance(logicModule).exports;

export const VERSION = 2;
export const FRAME_LIMIT = 8192;
export const CONTROL_LIMIT = 512;
export const tokenPattern = /^[0-9a-f]{64}$/;
export const sessionPattern = /^[0-9a-f]{32}$/;
const codePattern = /^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{12}$/;
export const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function normalizeCode(code) {
  if (typeof code !== "string" || code.length > 32) return null;
  const normalized = code.replace(/[ -]/g, "").toUpperCase().replaceAll("O", "0").replace(/[IL]/g, "1");
  return codePattern.test(normalized) ? normalized : null;
}

const uint = (x, max = 2_147_483_647) => Number.isSafeInteger(x) && x >= 0 && x <= max;
const id = x => typeof x === "string" && sessionPattern.test(x);
const exact = (x, names) => Object.keys(x).length === names.length && names.every(n => Object.hasOwn(x, n));

export function frame(text) {
  if (typeof text !== "string" || text.length > FRAME_LIMIT ||
      new TextEncoder().encode(text).length > FRAME_LIMIT) return null;
  try {
    const x = JSON.parse(text);
    return x && !Array.isArray(x) && typeof x === "object" && x.v === VERSION &&
      typeof x.type === "string" ? x : null;
  } catch { return null; }
}

// Numeric operands are sent instead of strings. Answers are derived only in the Remote view.
const card = c => Array.isArray(c) && c.length === 3 && uint(c[0], 18) && (c[1] === 1 || c[1] === -1) &&
  uint(c[2], 9) && logic.valid_card(c[0], c[1], c[2]) === 1;

export function relayKind(x) {
  switch (x.type) {
    case "sync":
      return exact(x, ["v", "type", "epoch", "deckVersion", "version", "screen", "index", "elapsed", "cards",
        "deck", "zero", "count", "timer"]) &&
        id(x.epoch) && id(x.deckVersion) && uint(x.version) && uint(x.screen, 3) && uint(x.index, 53) &&
        uint(x.elapsed, 86_400_000) && uint(x.deck, 3) && uint(x.zero, 1) && uint(x.count, 45) && uint(x.timer, 1) &&
        Array.isArray(x.cards) && x.cards.length <= 54 && x.cards.every(card) &&
        logic.valid_snapshot(x.version, x.screen, x.index, x.cards.length, x.elapsed,
          x.deck, x.zero, x.count, x.timer) === 1 ? 1 : 0;
    case "ack":
      return exact(x, ["v", "type", "epoch", "id", "result"]) &&
        id(x.epoch) && id(x.id) && uint(x.result, 4) && x.result > 0 ? 2 : 0;
    case "command":
      return exact(x, ["v", "type", "epoch", "id", "baseVersion", "action", "value"]) &&
        id(x.epoch) && id(x.id) && uint(x.baseVersion) && uint(x.action, 10) && uint(x.value, 45) &&
        logic.valid_command(x.action, x.value) === 1 ? 3 : 0;
    case "requestSync":
      return exact(x, ["v", "type"]) ? 4 : 0;
    default: return 0;
  }
}
