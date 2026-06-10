// src/overdrive/probe.mjs
import { loadMeter, saveMeter, accumulate } from "./metering.mjs";

// Pure: pull merged usage out of an SSE message stream body.
export function parseUsageFromSSE(text) {
  const usage = { model: "" };
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (!s.startsWith("data:")) continue;
    let obj;
    try { obj = JSON.parse(s.slice(5).trim()); } catch { continue; }
    if (obj.type === "message_start" && obj.message) {
      usage.model = obj.message.model || usage.model;
      Object.assign(usage, obj.message.usage || {});
    } else if (obj.type === "message_delta" && obj.usage) {
      Object.assign(usage, obj.usage); // output_tokens lands here
    }
  }
  return usage;
}

const isMessagesUrl = (u) => typeof u === "string" ? /\/v1\/messages\b/.test(u)
  : !!(u && u.url && /\/v1\/messages\b/.test(u.url));

// Installs a globalThis.fetch wrapper. Returns an uninstall fn.
// Fully fault-isolated: any failure falls back to the original fetch.
export function installProbe(config = {}, dir, sessionId) {
  const original = globalThis.fetch;
  const overrides = config.pricing || {};
  globalThis.fetch = async function (input, init) {
    const res = await original(input, init);
    try {
      const url = typeof input === "string" ? input : input?.url;
      if (isMessagesUrl(url) && res && res.body) {
        const clone = res.clone();
        clone.text().then((body) => {
          try {
            const usage = parseUsageFromSSE(body);
            usage.__turn = true;
            const meter = accumulate(loadMeter(dir, sessionId, usage.model), usage, overrides);
            saveMeter(dir, meter);
          } catch { /* metering is best-effort */ }
        }).catch(() => {});
      }
    } catch { /* never perturb the request */ }
    return res;
  };
  return function uninstall() { globalThis.fetch = original; };
}
