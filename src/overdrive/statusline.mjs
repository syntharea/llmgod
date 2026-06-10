// src/overdrive/statusline.mjs
import { newestMeter } from "./metering.mjs";
import { homedir } from "os";
import { join } from "path";

// stdin: Claude Code statusLine payload. Field names are defensive — confirm
// against code.claude.com/docs/en/statusline; unknown fields are simply dropped.
export function formatStatusline(stdin = {}, meter = null) {
  const parts = [];

  const ctx = stdin?.context?.used_pct ?? stdin?.context_percent;
  if (typeof ctx === "number" && isFinite(ctx)) parts.push(`ctx ${Math.round(ctx)}%`);

  const usd = stdin?.cost?.total_cost_usd ?? (meter?.cost?.priced ? meter.cost.usd : null);
  if (typeof usd === "number" && isFinite(usd)) parts.push(`$${usd.toFixed(2)}`);

  if (meter) {
    const t = meter.tokens;
    if (t && (t.cacheRead + t.input + t.cacheCreate) > 0)
      parts.push(`cache ${Math.round((meter.cacheHitRate || 0) * 100)}%`);
  }

  return parts.join(" · ");
}

async function readStdin() {
  let data = "";
  for await (const chunk of process.stdin) data += chunk;
  try { return JSON.parse(data); } catch { return {}; }
}

if (import.meta.main) {
  try {
    const dir = join(homedir(), ".llmgod");
    const stdin = await readStdin();
    process.stdout.write(formatStatusline(stdin, newestMeter(dir)));
  } catch { /* a broken statusline must never break the prompt */ }
}
