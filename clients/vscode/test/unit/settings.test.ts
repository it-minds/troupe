import assert from "node:assert/strict";
import { test } from "node:test";
import { parseExplain, rows, type Row } from "../../src/settings.js";

// The shape `troupe config --explain --json` prints (apps/troupe_core/lib/troupe/config/
// explain.ex), cut down: a user file that sets the model, a project file that would set
// the endpoint but is not trusted, and one warning.
const user = "C:\\Users\\me\\AppData\\Roaming/troupe/config.yaml";
const project = "c:/src/app/.troupe/config.yaml";

const step = (layer: string, value: unknown, source: string | null = null, ignored: string | null = null) => ({
  layer,
  source,
  value,
  from: null,
  ignored,
});

const explain = {
  workspace: "C:/src/app",
  trusted: false,
  files: [
    { layer: "user", path: user, exists: true },
    { layer: "project", path: project, exists: true },
    { layer: "local", path: "c:/src/app/.troupe/config.local.yaml", exists: false },
  ],
  keys: [
    { key: "provider", value: "openai", layer: "user", source: user, ladder: [step("default", "anthropic"), step("user", "openai", user)] },
    {
      key: "base_url",
      value: "https://gw.example/v1",
      layer: "user",
      source: user,
      ladder: [step("default", null), step("user", "https://gw.example/v1", user), step("project", "http://evil.example", project, "not trusted")],
    },
    { key: "api_key", value: "sk-a...yz", layer: "user", source: user, ladder: [step("default", null), step("user", "sk-a...yz", user)] },
    { key: "models.default", value: "big-1", layer: "user", source: user, ladder: [step("default", "claude-sonnet-5"), step("user", "big-1", user)] },
    { key: "models.cheap", value: "small-1", layer: "project", source: project, ladder: [step("default", null), step("project", "small-1", project)] },
    { key: "models.expensive", value: null, layer: "default", source: null, ladder: [step("default", null)] },
    {
      key: "providers",
      value: { gateway: { type: "openai", base_url: "https://gw.example/v1", api_key: "sk-b...yz" } },
      layer: "user",
      source: user,
      ladder: [step("default", {}), step("user", {}, user)],
    },
    { key: "max_turns", value: 60, layer: "project", source: project, ladder: [step("default", 40), step("project", 60, project)] },
    { key: "watch", value: false, layer: "default", source: null, ladder: [step("default", false)] },
    { key: "read_roots", value: [], layer: "default", source: null, ladder: [step("default", [])] },
  ],
  warnings: [{ level: "warning", source: project, line: 4, key: "max_tokns", message: "max_tokns is not a key Troupe knows: max_tokens?" }],
  refusals: [],
};

const shown = rows(parseExplain(JSON.stringify(explain)));
const group = (label: string) => shown.find((r) => r.label === label)?.children ?? [];
const row = (rows: Row[], label: string) => rows.find((r) => r.label === label);

test("the model: provider, endpoint, whether there is a key, and the three models, from where they were set", () => {
  const model = group("Model");
  assert.deepEqual(
    model.map((r) => [r.label, r.description]),
    [
      ["Provider", "openai · user"],
      ["Endpoint", "https://gw.example/v1 · user"],
      ["Key", "set · user"],
      ["Default model", "big-1 · user"],
      ["Cheap model", "small-1 · project"],
      ["Expensive model", "the default model · default"],
      ["gateway/", "openai · https://gw.example/v1 · user"],
    ],
  );
  assert.deepEqual(row(model, "Default model")?.open, { path: user, exists: true });
  assert.equal(row(model, "Expensive model")?.open, undefined);
});

test("no key is shown, not even masked, in a row, a tooltip or a provider", () => {
  const text = JSON.stringify(shown);
  assert.doesNotMatch(text, /sk-/);
});

test("a repository's value that was ignored says so, with why", () => {
  const endpoint = row(group("Model"), "Endpoint");
  assert.equal(endpoint?.icon, "warning");
  assert.match(endpoint?.tooltip ?? "", /project: `http:\/\/evil\.example` \(ignored: not trusted\)/);
});

test("what is changed from the defaults, not counting the model", () => {
  assert.deepEqual(
    group("Changed from the defaults").map((r) => [r.label, r.description]),
    [["max_turns", "60 · project"]],
  );
});

test("the files, a missing one to make, and whether the workspace is trusted", () => {
  const files = group("Files");
  assert.deepEqual(files.map((r) => r.label), ["user", "project", "local", "Not trusted"]);
  // In the workspace by its path there, whatever the case of the drive; elsewhere, as Windows writes it.
  assert.deepEqual(files.map((r) => r.description).slice(0, 3), [
    "C:\\Users\\me\\AppData\\Roaming\\troupe\\config.yaml",
    ".troupe/config.yaml",
    ".troupe/config.local.yaml (not there)",
  ]);
  assert.deepEqual(row(files, "local")?.open, { path: "c:/src/app/.troupe/config.local.yaml", exists: false });
  assert.equal(row(files, "local")?.icon, "new-file");
});

test("a warning opens its file at its line", () => {
  const [warning] = group("Problems");
  assert.deepEqual(warning?.open, { path: project, line: 4, exists: true });
  assert.equal(warning?.description, `${project}:4`);
});

test("every setting, collapsed, values as a person reads them", () => {
  const all = shown.find((r) => r.label === "All settings");
  assert.equal(all?.expanded, false);
  assert.equal(row(all?.children ?? [], "watch")?.description, "false · default");
  assert.equal(row(all?.children ?? [], "read_roots")?.description, "none · default");
});

test("nothing changed is said, not left empty; nothing to complain of has no Problems", () => {
  const plain = rows(parseExplain(JSON.stringify({ ...explain, keys: [], warnings: [] })));
  assert.deepEqual(plain.find((r) => r.label === "Changed from the defaults")?.children?.map((r) => r.label), [
    "Nothing else: Troupe's defaults",
  ]);
  assert.equal(plain.find((r) => r.label === "Problems"), undefined);
});

test("output that is not settings is an error, not an empty panel", () => {
  assert.throws(() => parseExplain("troupe: could not start"));
  assert.throws(() => parseExplain(JSON.stringify({ hello: 1 })), /something other than settings/);
});
