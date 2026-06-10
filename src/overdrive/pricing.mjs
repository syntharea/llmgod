// src/overdrive/pricing.mjs
// USD per 1,000,000 tokens (standard <=200k tier). VERIFY against current public
// pricing at platform.claude.com/docs/about-claude/pricing before release.
export const PRICE_TABLE = {
  "claude-opus-4-8":   { input: 15, output: 75, cacheWrite1h: 30,  cacheWrite5m: 18.75, cacheRead: 1.5 },
  "claude-sonnet-4-6": { input: 3,  output: 15, cacheWrite1h: 6,   cacheWrite5m: 3.75,  cacheRead: 0.3 },
  "claude-haiku-4-5":  { input: 1,  output: 5,  cacheWrite1h: 2,   cacheWrite5m: 1.25,  cacheRead: 0.1 },
};

export function normalizeModel(model) {
  if (!model) return "";
  return String(model).replace(/\[1m\]$/i, "").replace(/^.*\//, "").trim();
}

export function resolvePrice(model, overrides = {}) {
  if (overrides && overrides[model]) return overrides[model];
  const norm = normalizeModel(model);
  if (overrides && overrides[norm]) return overrides[norm];
  return PRICE_TABLE[norm] || null;
}

export function computeCost(model, tokens = {}, overrides = {}) {
  const p = resolvePrice(model, overrides);
  if (!p) return { usd: 0, priced: false };
  const per = (n, rate) => ((Number(n) || 0) / 1e6) * (Number(rate) || 0);
  const usd =
    per(tokens.input, p.input) +
    per(tokens.output, p.output) +
    per(tokens.cacheCreate, p.cacheWrite1h ?? p.cacheWrite5m ?? p.input) +
    per(tokens.cacheRead, p.cacheRead);
  return { usd, priced: true };
}
