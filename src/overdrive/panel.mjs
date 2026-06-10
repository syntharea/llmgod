// src/overdrive/panel.mjs
import { newestMeter } from "./metering.mjs";
import { homedir } from "os";
import { join } from "path";
import { readFileSync } from "fs";

const n = (x) => (Number(x) || 0).toLocaleString();

export function formatPanel(meter, config = {}) {
  if (!meter) return "llmgod xray: no metering data yet — run a turn first.";
  const t = meter.tokens;
  const thirdParty = !!(config.baseURL && !/anthropic\.com/i.test(config.baseURL));
  const lines = [
    `Session ${meter.sessionId}  ·  ${meter.model || "unknown"}`,
    ``,
    `  input        ${n(t.input)}`,
    `  output       ${n(t.output)}`,
    `  cache write  ${n(t.cacheCreate)}`,
    `  cache read   ${n(t.cacheRead)}`,
    `  cache hit    ${Math.round((meter.cacheHitRate || 0) * 100)}%`,
    ``,
    meter.cost.priced
      ? `  cost         $${meter.cost.usd.toFixed(4)}`
      : `  cost         (no price for model — set provider.json.pricing)`,
    `  billing header ${thirdParty ? "disabled (third-party cache fix active)" : "enabled (Anthropic)"}`,
  ];
  return lines.join("\n");
}

if (import.meta.main) {
  try {
    const dir = join(homedir(), ".llmgod");
    let config = {};
    try { config = JSON.parse(readFileSync(join(dir, "provider.json"), "utf8")); } catch {}
    process.stdout.write(formatPanel(newestMeter(dir), config) + "\n");
  } catch (e) {
    process.stdout.write("llmgod xray: unavailable\n");
  }
}
