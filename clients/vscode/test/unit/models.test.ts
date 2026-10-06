import assert from "node:assert/strict";
import { test } from "node:test";
import { MODELS_CONTEXT, modelsFailed, modelsGroup, parseModels, type Model } from "../../src/models.js";
import { failure, type Row } from "../../src/settings.js";

// The shape `troupe models --json` prints (apps/troupe_core/lib/troupe/config/models.ex,
// Decision 783), cut down: a session-wide provider behind a gateway that answered just
// now, a named one, `gw`, that did not answer this time and is read from the cache, a
// default model the gateway does not serve, a price from `models.prices`, and a provider
// from opencode with no key that was never asked.
const now = new Date("2026-10-05T12:00:00Z");
const hoursAgo = (h: number) => new Date(now.getTime() - h * 3_600_000).toISOString();

const model = (m: Partial<Model> & { id: string }): Model => ({
  provider: null,
  model: m.id,
  context: null,
  input: null,
  output: null,
  price_source: null,
  source: "config",
  key: true,
  served: true,
  nearest: [],
  ...m,
});

const json = {
  models: [
    model({ id: "gpt-oss-120b", context: 131_072, input: 0.1, output: 0.5, price_source: "catalog", source: "catalog" }),
    // Troupe's fallback window, beside `served: false`: not a window anyone said (D70).
    model({ id: "house-model", context: 200_000, input: 0.5, output: 1.5, price_source: "config", served: false, nearest: ["qwen3-235b"] }),
    model({ id: "llama-local", context: 32_768, input: 0.05, output: 0.1, price_source: "config", source: "catalog" }),
    model({ id: "qwen3.5", context: 200_000, served: false, nearest: ["qwen3.6-35b", "qwen3-235b"] }),
    model({ id: "gw/qwen3-235b", provider: "gw", model: "qwen3-235b", context: 131_072, input: 0.22, output: 0.88, price_source: "catalog", source: "catalog" }),
    model({ id: "oc/claude-sonnet-5", provider: "oc", model: "claude-sonnet-5", context: 1_000_000, source: "opencode", key: false, served: null }),
  ],
  roles: { default: "qwen3.5", cheap: "gw/qwen3-235b", expensive: "gpt-oss-120b" },
  catalog: {
    path: "C:\\Users\\me\\AppData\\Roaming\\troupe\\catalog.json",
    fetched_at: hoursAgo(0),
    sources: [
      {
        provider: "gw",
        type: "openai",
        base_url: "https://gw.example/v1",
        url: "https://gw.example/model_group/info",
        models: 4,
        fetched_at: hoursAgo(26),
        status: "failed",
        error: "401 unauthorized: the key was refused",
        failed_at: hoursAgo(2),
      },
      {
        provider: null,
        type: "openai",
        base_url: "https://gw.example/v1",
        url: "https://gw.example/model_group/info",
        models: 4,
        fetched_at: hoursAgo(0),
        status: "fetched",
        error: null,
        failed_at: null,
      },
    ],
  },
  providers: [{ name: "gw", type: "openai", base_url: "https://gw.example/v1", auth: "bearer", source: "yaml", key: true, models: ["qwen3-235b"] }],
};

const group = modelsGroup(parseModels(JSON.stringify(json)), now);
const row = (label: string) => group.children?.find((r) => r.label === label);
const said = (r: Row | undefined) => [r?.label, r?.description];

test("the group: how many models and when they were listed, with the button that asks again", () => {
  assert.equal(group.label, "Models");
  assert.equal(group.description, "6 models · listed just now");
  assert.equal(group.context, MODELS_CONTEXT);
  assert.equal(group.expanded, true);
});

test("each model with its window and price, and where they came from", () => {
  assert.deepEqual(said(row("gpt-oss-120b")), ["gpt-oss-120b", "expensive · 131k window · $0.10/$0.50 · from openai's list"]);
  assert.deepEqual(said(row("gw/qwen3-235b")), ["gw/qwen3-235b", "cheap · 131k window · $0.22/$0.88 · from gw's list"]);
  // A price from `models.prices` for a model the provider's list has without one.
  // Cents under a dime to three places, as `troupe models` prints them.
  assert.deepEqual(said(row("llama-local")), ["llama-local", "32k window · $0.050/$0.10 (models.prices) · from openai's list"]);
  assert.match(row("gw/qwen3-235b")?.tooltip ?? "", /Window: 131,072 tokens, from gw's list\./);
  assert.match(row("llama-local")?.tooltip ?? "", /Price: \$0\.050 in, \$0\.10 out, a million tokens, from models\.prices in your config\./);
});

test("the default, cheap and expensive models are marked", () => {
  assert.equal(row("gw/qwen3-235b")?.icon, "star-full");
  assert.equal(row("gpt-oss-120b")?.icon, "star-full");
  assert.equal(row("llama-local")?.icon, "circle-small");
  assert.match(row("gw/qwen3-235b")?.tooltip ?? "", /^\*\*gw\/qwen3-235b\*\*: the cheap model\./);
});

test("a model its provider does not serve is flagged, with what it does serve, and no window", () => {
  const notServed = row("qwen3.5");
  assert.deepEqual(said(notServed), ["qwen3.5", "default · not served by openai"]);
  assert.equal(notServed?.icon, "warning");
  assert.match(notServed?.tooltip ?? "", /openai's list, fetched just now, does not have it, so a turn on it fails\. It serves qwen3\.6-35b, qwen3-235b\./);
  // The 200,000 in the JSON is Troupe's fallback, not the model's window.
  assert.doesNotMatch(JSON.stringify(notServed), /200|window/);

  // A price someone wrote down for it is still said; the window still is not.
  const priced = row("house-model");
  assert.deepEqual(said(priced), ["house-model", "not served by openai · $0.50/$1.50 (models.prices)"]);
  assert.match(priced?.tooltip ?? "", /Price: \$0\.50 in, \$1\.50 out, a million tokens, from models\.prices in your config\./);
  assert.doesNotMatch(JSON.stringify(priced), /200|window/);

  // A `troupe` from 0.8.6 gives such a model no window at all (Decision 799): the same rows.
  const unwindowed = json.models.map((m) => (m.served === false ? { ...m, context: null } : m));
  const corrected = modelsGroup(parseModels(JSON.stringify({ ...json, models: unwindowed })), now);
  for (const id of ["qwen3.5", "house-model"]) assert.deepEqual(corrected.children?.find((r) => r.label === id), row(id));
});

test("a model with no key and no answer yet says so; a window past a million in millions", () => {
  const oc = row("oc/claude-sonnet-5");
  assert.equal(oc?.description, "1M window · no price · from opencode · no key");
  assert.match(oc?.tooltip ?? "", /No key is set for oc\./);
  assert.match(oc?.tooltip ?? "", /Whether oc serves it is not known/);
});

test("each provider's list: how many and when, and one that did not answer says why", () => {
  assert.deepEqual(said(group.children?.[0]), ["gw's list", "did not answer 2 hours ago: 401 unauthorized: the key was refused"]);
  assert.equal(group.children?.[0]?.icon, "warning");
  assert.match(group.children?.[0]?.tooltip ?? "", /4 models of it are from the cache, fetched 1 day ago\./);
  assert.deepEqual(said(group.children?.[1]), ["openai's list", "4 models, fetched just now"]);
});

test("no key is shown, not even masked", () => {
  assert.doesNotMatch(JSON.stringify(group), /sk-/);
});

test("roles left unset are the default model's, which carries all three", () => {
  const one = modelsGroup(
    parseModels(JSON.stringify({ models: [model({ id: "m", context: 200_000 })], roles: { default: "m", cheap: "m", expensive: "m" }, catalog: null, providers: [] })),
    now,
  );
  assert.equal(one.description, "1 model");
  assert.equal(one.children?.[0]?.description, "default, cheap, expensive · 200k window · no price · from your config");
  assert.match(one.children?.[0]?.tooltip ?? "", /the default, cheap and expensive model\./);
});

test("a gateway's long list starts folded; an empty one says what to do", () => {
  const many = Array.from({ length: 21 }, (_, i) => model({ id: `m${i}` }));
  assert.equal(modelsGroup({ models: many, roles: { default: "m0" }, catalog: null }, now).expanded, false);
  assert.deepEqual(modelsGroup({ models: [], roles: {}, catalog: null }, now).children?.map((r) => r.label), ["None: set models.default or a provider"]);
});

test("output that is not models is an error, not an empty group", () => {
  assert.throws(() => parseModels("troupe: could not start"));
  assert.throws(() => parseModels(JSON.stringify({ hello: 1 })), /something other than models/);
});

test("a failure is one line in the group, the rest on hover, and never a key a reason quotes", () => {
  const reason = 'config.yaml:3: api_key: sk-live-abcdef123456 is not a string\nAuthorization: Bearer abc.def.ghi\napi_key="sk-ant-0987654321"';
  const failed = modelsFailed(failure("Troupe could not list its models", reason, "an older `troupe` does not know it"));

  assert.equal(failed.label, "Models");
  assert.equal(failed.context, MODELS_CONTEXT);
  const [line] = failed.children ?? [];
  assert.equal(line?.label, "Troupe could not list its models");
  assert.equal(line?.description, "config.yaml:3: api_key: (a key) is not a string");
  assert.equal(line?.icon, "error");
  assert.match(line?.tooltip ?? "", /an older `troupe` does not know it/);

  const text = JSON.stringify(failed);
  for (const secret of ["sk-", "abcdef123456", "abc.def.ghi", "0987654321"]) assert.ok(!text.includes(secret), secret);
});
