// The model settings: what a form sends, and what the daemon and the plane answer.
//
// The rules that matter are the ones a screen would get quietly wrong — an empty key
// field keeps the saved key, a cleared field removes rather than saves an empty string,
// a key never comes back, and the organisation's defaults never carry one. Each is
// pinned twice: once on the pure functions that build the parameters, and once end to
// end against the fake daemon, so a change on either side fails here.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import {
  DaemonClient,
  applyClientDefaults,
  clientDefaults,
  configSetParams,
  describeOffer,
  describeOverride,
  discoveryParams,
  formFromConfig,
  modelConfigError,
  tokenCount,
} from "../src/index.js";
import type { DaemonEndpoint, ModelConfig, ModelForm } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";
import { startHarness, type Harness } from "./support/harness.js";
import { GATEWAY_DEFAULTS } from "./support/plane.js";

const saved: ModelConfig = {
  config_dir: "/home/ada/.config/troupe",
  path: "/home/ada/.config/troupe/config.yaml",
  exists: true,
  provider: "anthropic",
  base_url: null,
  auth: "api_key",
  api_key_set: true,
  api_key_source: "file",
  models: { default: "claude-opus-5", cheap: "claude-haiku-4-5", expensive: null },
  overrides: [],
};

describe("the form, before anything is sent", () => {
  it("starts from what is saved, with the key field empty whether or not a key is set", () => {
    const form = formFromConfig(saved);
    assert.deepEqual(form, {
      provider: "anthropic",
      baseUrl: "",
      auth: "api_key",
      apiKey: "",
      models: { default: "claude-opus-5", cheap: "claude-haiku-4-5", expensive: "" },
    });
  });

  it("keeps the saved key when the key field is left empty", () => {
    const params = configSetParams(formFromConfig(saved));
    assert.equal("api_key" in params, false);
  });

  it("sends a typed key, trimmed, and removes one only when asked to", () => {
    const form: ModelForm = { ...formFromConfig(saved), apiKey: "  sk-new \n" };
    assert.equal(configSetParams(form).api_key, "sk-new");
    // Removing wins over whatever is in the field: the button says what it does.
    assert.equal(configSetParams(form, { removeKey: true }).api_key, "");
  });

  it("sends a cleared base URL or role as null, which removes it", () => {
    const form: ModelForm = {
      ...formFromConfig({ ...saved, base_url: "https://proxy.example" }),
      baseUrl: "  ",
      models: { default: "claude-opus-5", cheap: "", expensive: " " },
    };
    assert.deepEqual(configSetParams(form), {
      provider: "anthropic",
      base_url: null,
      auth: "api_key",
      models: { default: "claude-opus-5", cheap: null, expensive: null },
    });
  });

  it("asks for models with the unsaved values, and leaves the key to the daemon when none is typed", () => {
    const form: ModelForm = { ...formFromConfig(saved), provider: "openai", baseUrl: "https://gw.example/v1", auth: "bearer" };
    assert.deepEqual(discoveryParams(form), { provider: "openai", base_url: "https://gw.example/v1", auth: "bearer" });
    assert.equal(discoveryParams({ ...form, apiKey: "sk-typed" }).api_key, "sk-typed");
  });
});

describe("the organisation's defaults", () => {
  it("fill in provider, address, auth and models, and never the key", () => {
    const form: ModelForm = { ...formFromConfig(saved), apiKey: "sk-mine" };
    const next = applyClientDefaults(form, { ...GATEWAY_DEFAULTS, auth: "bearer" });
    assert.deepEqual(next, {
      provider: "openai",
      baseUrl: "https://llm-gw.example/v1",
      auth: "bearer",
      apiKey: "sk-mine",
      // The expensive role was not named, and the old one was an Anthropic model: it
      // goes rather than being sent to a gateway that has never heard of it.
      models: { default: "glm-5.2", cheap: "qwen3.6-35b", expensive: "" },
    });
  });

  it("keep what the plane has no opinion on when the provider stays the same", () => {
    const form: ModelForm = { ...formFromConfig(saved), baseUrl: "https://proxy.example" };
    const next = applyClientDefaults(form, {
      configured: true,
      provider: "anthropic",
      base_url: null,
      auth: null,
      models: { cheap: "claude-haiku-4-5" },
    });
    assert.equal(next.baseUrl, "https://proxy.example");
    assert.equal(next.models.default, "claude-opus-5");
  });

  it("change nothing when the organisation has set nothing", () => {
    const form = formFromConfig(saved);
    assert.equal(applyClientDefaults(form, { configured: false, provider: null, base_url: null, auth: null, models: null }), form);
  });
});

describe("what the panel says", () => {
  it("describes a model by what it reads and what it costs, leaving out what nobody reported", () => {
    assert.equal(
      describeOffer({ id: "claude-opus-5", context: 200_000, max_output: 64_000, input: 5, output: 25 }),
      "200k tokens of context · $5.00 in, $25.00 out per million tokens",
    );
    assert.equal(describeOffer({ id: "glm-5.2", context: 128_000, max_output: null, input: null, output: null }), "128k tokens of context");
    assert.equal(describeOffer({ id: "x", context: null, max_output: null, input: 0.25, output: null }), "$0.25 per million tokens in");
    assert.equal(tokenCount(1_000_000), "1M");
    assert.equal(tokenCount(32_768), "32.8k");
  });

  it("says what overrides the file, and by whose hand", () => {
    assert.equal(
      describeOverride({ source: "project", detail: "c:/repo/.troupe/config.yaml sets provider, models" }),
      "This is overridden by a project's own settings: c:/repo/.troupe/config.yaml sets provider, models.",
    );
    assert.match(describeOverride({ source: "env", detail: "TROUPE_PROVIDER=openai" }), /environment variable/);
  });
});

describe("the model settings on the daemon", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon({ overrides: [{ source: "env", detail: "TROUPE_MODEL is set" }] });
    await daemon.start();
    client = new DaemonClient(endpointOf(daemon));
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("reads nothing saved yet, then what was saved, and never the key", async () => {
    const empty = await client.modelConfig();
    assert.equal(empty.exists, false);
    assert.equal(empty.api_key_set, false);
    assert.deepEqual(empty.overrides, [{ source: "env", detail: "TROUPE_MODEL is set" }]);

    const form: ModelForm = { ...formFromConfig(empty), apiKey: "sk-ant-secret", models: { default: "claude-opus-5", cheap: "claude-haiku-4-5", expensive: "" } };
    const written = await client.setModelConfig(configSetParams(form));
    assert.equal(written.exists, true);
    assert.equal(written.api_key_set, true);
    assert.equal(written.api_key_source, "file");
    assert.equal(written.models.default, "claude-opus-5");
    assert.equal(JSON.stringify(written).includes("sk-ant-secret"), false);

    // A command, so it carries an id the daemon can deduplicate on.
    const set = daemon.calls.find((c) => c.method === "config.set");
    assert.match(String(set?.params["command_id"]), /^c-/);

    const reread = await client.modelConfig();
    assert.deepEqual(reread, written);
  });

  it("keeps the key through a save with the field empty, and removes it only when asked", async () => {
    const kept = await client.setModelConfig(configSetParams({ ...formFromConfig(await client.modelConfig()), models: { default: "claude-opus-5", cheap: "", expensive: "" } }));
    assert.equal(kept.api_key_set, true);
    assert.equal(kept.models.cheap, null);
    assert.equal(daemon.settings.api_key, "sk-ant-secret");

    const removed = await client.setModelConfig(configSetParams(formFromConfig(kept), { removeKey: true }));
    assert.equal(removed.api_key_set, false);
    assert.equal(removed.api_key_source, null);
  });

  it("discovers models with a key that is not saved, and says so when the key is wrong", async () => {
    const form: ModelForm = { ...formFromConfig(await client.modelConfig()), apiKey: "wrong" };
    const refused = await client.discoverModels(discoveryParams(form));
    assert.deepEqual(refused.models, []);
    assert.deepEqual(refused.failures, [{ provider: "anthropic", reason: "401 unauthorized" }]);

    const offered = await client.discoverModels(discoveryParams({ ...form, provider: "openai", apiKey: "sk-gw" }));
    assert.deepEqual(
      offered.models.map((m) => m.id),
      ["glm-5.2", "qwen3.6-35b"],
    );
    assert.equal(offered.models[0]?.input, null);

    // Discovering saves nothing: the file still says what it said.
    assert.equal((await client.modelConfig()).provider, "anthropic");
  });

  it("refuses a provider it does not know, and says why", async () => {
    await assert.rejects(
      () => client.setModelConfig({ provider: "gemini" }),
      (e: unknown) => /provider must be one of/.test(modelConfigError(e)),
    );
  });

  it("an older daemon is told apart from a broken one", async () => {
    const old = new FakeDaemon({ modelSettings: false });
    await old.start();
    const other = new DaemonClient(endpointOf(old));
    try {
      await assert.rejects(
        () => other.modelConfig(),
        (e: unknown) => modelConfigError(e) === "This daemon does not support model settings yet; update troupe-daemon.",
      );
    } finally {
      other.disconnect();
      await old.stop();
    }
  });
});

describe("the organisation's defaults, from the plane", () => {
  let h: Harness;

  after(async () => {
    await h.stop();
  });

  it("are read by anybody signed in, and carry no key", async () => {
    h = await startHarness();
    const auth = await h.signIn();
    const defaults = await clientDefaults((m, p) => auth.rpc(m, p));
    assert.deepEqual(defaults, GATEWAY_DEFAULTS);
    assert.equal("api_key" in defaults, false);
  });

  it("say so when the organisation has set nothing", async () => {
    const bare = await startHarness({ plane: { clientDefaults: { configured: false } } });
    try {
      const auth = await bare.signIn();
      assert.equal((await clientDefaults((m, p) => auth.rpc(m, p))).configured, false);
    } finally {
      await bare.stop();
    }
  });
});

function endpointOf(daemon: FakeDaemon): DaemonEndpoint {
  return { transport: "ws", port: daemon.port, token: daemon.token };
}
