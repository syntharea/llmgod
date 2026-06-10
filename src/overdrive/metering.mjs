// src/overdrive/metering.mjs
import { readFileSync, writeFileSync, renameSync, mkdirSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { computeCost } from "./pricing.mjs";

export function emptyMeter(sessionId, model = "") {
  const now = Date.now();
  return {
    sessionId, model, startedAt: now, updatedAt: now, turns: 0,
    tokens: { input: 0, output: 0, cacheCreate: 0, cacheRead: 0 },
    cacheHitRate: 0, cost: { usd: 0, priced: false },
  };
}

// Pure: fold one API usage record into a meter, returning a new meter.
export function accumulate(meter, usage = {}, overrides = {}) {
  const t = meter.tokens;
  const tokens = {
    input: t.input + (usage.input_tokens || 0),
    output: t.output + (usage.output_tokens || 0),
    cacheCreate: t.cacheCreate + (usage.cache_creation_input_tokens || 0),
    cacheRead: t.cacheRead + (usage.cache_read_input_tokens || 0),
  };
  const cacheable = tokens.input + tokens.cacheCreate + tokens.cacheRead;
  const cacheHitRate = cacheable > 0 ? tokens.cacheRead / cacheable : 0;
  const model = usage.model || meter.model;
  return {
    ...meter, model, updatedAt: Date.now(),
    turns: meter.turns + (usage.__turn ? 1 : 0),
    tokens, cacheHitRate, cost: computeCost(model, tokens, overrides),
  };
}

const dirFor = (dir) => join(dir, "metering");
export const meterPath = (dir, id) => join(dirFor(dir), `session-${id}.json`);

export function saveMeter(dir, meter) {
  mkdirSync(dirFor(dir), { recursive: true });
  const p = meterPath(dir, meter.sessionId);
  const tmp = p + ".tmp";
  writeFileSync(tmp, JSON.stringify(meter));
  renameSync(tmp, p);
}

export function loadMeter(dir, id, model = "") {
  try { return JSON.parse(readFileSync(meterPath(dir, id), "utf8")); }
  catch { return emptyMeter(id, model); }
}

export function newestMeter(dir) {
  try {
    const files = readdirSync(dirFor(dir)).filter((f) => f.startsWith("session-") && f.endsWith(".json"));
    if (!files.length) return null;
    const scored = files.map((f) => {
      const full = join(dirFor(dir), f);
      let updatedAt = 0;
      try { updatedAt = JSON.parse(readFileSync(full, "utf8")).updatedAt || 0; } catch {}
      return { f, mtime: statSync(full).mtimeMs, updatedAt };
    });
    scored.sort((a, b) => (b.mtime - a.mtime) || (b.updatedAt - a.updatedAt));
    return JSON.parse(readFileSync(join(dirFor(dir), scored[0].f), "utf8"));
  } catch { return null; }
}
