// The first run (troupe Decision 705): a fresh machine in local mode, one API key, and
// the app reaches a first working session without the docs — against the fake daemon,
// which holds the flow the way the real one does. Then the ways back in: Setup in the
// rail, and the offer under a refused key. And each screen on its own, with a flow
// fixture and a spy for what it sends.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import type { DaemonClient, SetupFlow, SetupStepName } from "@troupe/client";
import { App } from "../src/App";
import { Finish } from "../src/views/Onboarding/Finish";
import { Key } from "../src/views/Onboarding/Key";
import { PickModels } from "../src/views/Onboarding/PickModels";
import { Provider } from "../src/views/Onboarding/Provider";
import { Where } from "../src/views/Onboarding/Where";
import { Workspace } from "../src/views/Onboarding/Workspace";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, nav, render, says, type, waitFor } from "./support";

// jsdom lays nothing out, so it has nothing to scroll; the transcript asks anyway.
Element.prototype.scrollIntoView = function scrollIntoView() {};
// The page's WebSocket: see local-mode.test.tsx.
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon?.stop();
  daemon = null;
});

async function start(opts: ConstructorParameters<typeof FakeDaemon>[0]): Promise<FakeDaemon> {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  daemon = new FakeDaemon({ osUser: "ada", ...opts });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  return daemon;
}

/** The option card whose words begin with `label`, and whether it is the pressed one. */
function pressed(label: string): boolean {
  return button(label)?.getAttribute("aria-pressed") === "true";
}

function field(label: string): HTMLInputElement | HTMLTextAreaElement {
  const found = document.querySelector<HTMLInputElement | HTMLTextAreaElement>(`[aria-label="${label}"]`);
  if (!found) throw new Error(`no field labelled ${label}. The page says:\n${document.body.textContent ?? ""}`);
  return found;
}

describe("a fresh machine's first run", () => {
  it("reaches a first working session with one API key, and is not asked again", async () => {
    const fake = await start({ firstRun: true });
    unmount = render(<App />).unmount;

    // The theme first, pre-answered; Continue is enough.
    await waitFor(() => says("Welcome."), "the first run");
    button("Continue")!.click();

    // Where: this machine is pressed already.
    await waitFor(() => says("Where does the work run?"), "the where step");
    expect(pressed("Use my own machine and keys")).toBe(true);
    button("Continue")!.click();

    // Provider: Anthropic is pressed already; nothing is detected on this machine.
    await waitFor(() => says("Which model provider?"), "the provider step");
    expect(says("Already on this computer")).toBe(false);
    expect(pressed("Anthropic")).toBe(true);
    button("Continue")!.click();

    // Key: says where it goes, and that there is no keychain. A wrong key is refused
    // plainly and the step stays; the right one goes on.
    await waitFor(() => says("The key"), "the key step");
    expect(says(`${fake.settings.exists ? "" : ""}/home/ada/.config/troupe/config.yaml`)).toBe(true);
    expect(says("there is no keychain in this build")).toBe(true);
    type(field("API key"), "wrong");
    button("Check the key and continue")!.click();
    await waitFor(() => says("The provider refused the key: 401 unauthorized: the key was refused. Check it and try again."), "the refusal");
    expect(says("Which models?")).toBe(false);
    expect(fake.settings.exists).toBe(false);
    type(field("API key"), "sk-right");
    button("Check the key and continue")!.click();

    // Models: the suggestion is pressed, with what it reads and costs.
    await waitFor(() => says("Which models?"), "the models step");
    expect(pressed("claude-opus-5")).toBe(true);
    expect(says("200k tokens of context · $5.00 in, $25.00 out per million tokens")).toBe(true);
    button("Save these models and continue")!.click();

    // Workspace: the safe approval model is pressed, in two sentences.
    await waitFor(() => says("Where is the first project?"), "the workspace step");
    expect(pressed("Ask me first")).toBe(true);
    expect(says("nothing changes on disk until you say so")).toBe(true);
    type(field("Directory"), "/home/ada/project");
    button("Continue")!.click();

    // Finish: what was set up, and the first session with its suggested prompt.
    await waitFor(() => says("Ready"), "the finish step");
    expect(says("saved in /home/ada/.config/troupe/config.yaml")).toBe(true);
    expect((field("What to ask first") as HTMLTextAreaElement).value).toBe("Look around this directory and tell me what you find.");
    button("Start the first session")!.click();

    // The session: open in the app, started by the daemon in the project with the
    // prompt as its first input.
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the first session");
    expect(says("/home/ada/project")).toBe(true);
    const created = [...fake.sessions.values()].find((s) => s.workspace === "/home/ada/project");
    expect(created).toBeDefined();
    expect(created!.log.from(0).map((e) => [e.type, e.data["text"]])).toEqual([
      ["session_created", undefined],
      ["user_input", "Look around this directory and tell me what you find."],
    ]);

    // What the daemon was told, and what it wrote: the key went once, at its own step.
    expect(fake.settings).toMatchObject({ exists: true, provider: "anthropic", api_key: "sk-right", models: { default: "claude-opus-5", cheap: "claude-haiku-4-5" } });
    expect(fake.setupCompleted?.choice).toBe("local");
    const keyCalls = fake.calls.filter((c) => JSON.stringify(c.params).includes("sk-right"));
    expect(keyCalls.map((c) => `${c.method} ${(c.params["step"] as string) ?? ""}`)).toEqual(["setup.answer key"]);

    // A relaunch: straight to the list, with the session in it and no questions.
    unmount();
    unmount = render(<App />).unmount;
    await waitFor(() => says("/home/ada/project"), "the session list");
    expect(says("Welcome.")).toBe(false);
  });

  it("is re-run from Setup in the rail, and offered under a key the provider refused", async () => {
    const fake = await start({});
    const session = fake.seed("/home/ada/project");
    unmount = render(<App />).unmount;

    // A machine already set up: the list, and Setup one press away.
    await waitFor(() => says("/home/ada/project"), "the session list");
    expect(says("Welcome.")).toBe(false);
    nav("Setup")!.click();
    await waitFor(() => says("Where does the work run?"), "the questions again");
    expect(says("The first run's questions, again")).toBe(true);

    // A refused key in a session: the step under the error is a way into the same flow.
    nav("Sessions")!.click();
    const row = await waitFor(() => document.querySelector<HTMLButtonElement>("button.row"), "the session in the list");
    row.click();
    await waitFor(() => fake.calls.some((c) => c.method === "presence.set"), "the session to be open");
    session.log.append("llm_error", { reason: "the provider rejected the credentials (invalid x-api-key)" });
    const offer = await waitFor(() => button("Run setup"), "the offer under the error");
    expect(says("Check the key on This computer, under Models.")).toBe(true);
    offer.click();
    await waitFor(() => says("Where does the work run?"), "the setup screen");
  });

  it("ends at the sign-in screen for a plane, and reuses what is already on the machine", async () => {
    const fake = await start({ firstRun: true, env: { ANTHROPIC_API_KEY: "sk-from-env" }, opencode: { providers: ["portal"], default: "portal/qwen" } });
    unmount = render(<App />).unmount;
    await waitFor(() => says("Welcome."), "the first run");
    button("Continue")!.click();
    await waitFor(() => says("Where does the work run?"), "the where step");
    button("Continue")!.click();

    // What is here comes first, and the key in the environment is the pressed answer.
    await waitFor(() => says("Already on this computer"), "the provider step");
    expect(pressed("ANTHROPIC_API_KEY is set on this computer")).toBe(true);
    expect(says("opencode is set up here, with portal")).toBe(true);
    button("Continue")!.click();
    await waitFor(() => says("The key"), "the key step");
    expect(pressed("Keep it in ANTHROPIC_API_KEY")).toBe(true);
    button("Check the key and continue")!.click();
    await waitFor(() => says("Which models?"), "the models step");
    expect(fake.setup.key).toBe("{env:ANTHROPIC_API_KEY}");

    // Back to the start, a step at a time, and the other way: a plane records the
    // choice and signs in.
    button("Back")!.click();
    await waitFor(() => says("The key") && !says("Which models?"), "back to the key step");
    button("Back")!.click();
    await waitFor(() => says("Which model provider?"), "back to the provider step");
    button("Back")!.click();
    await waitFor(() => says("Where does the work run?"), "back to the where step");
    button("Sign in to my organisation")!.click();
    const address = await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="The plane\'s address"]'), "the address field");
    type(address, "https://troupe.example");
    button("Continue")!.click();
    await waitFor(() => says("Sign in next"), "the plane's finish");
    button("Finish and sign in")!.click();
    await waitFor(() => says("Use this computer only"), "the sign-in screen");
    expect(fake.setupCompleted?.choice).toBe("plane");
    expect(localStorage.getItem("troupe.pref.planeUrl")).toBe("https://troupe.example");
    expect(localStorage.getItem("troupe.pref.localOnly")).toBe("no");
  });
});

// -- each screen on its own --------------------------------------------------------

function flowAt(step: SetupStepName, extra: Partial<SetupFlow> = {}): SetupFlow {
  const all: SetupStepName[] = ["where", "provider", "key", "models", "workspace", "finish"];
  const done = all.slice(0, all.indexOf(step));
  return {
    needed: true,
    completed: null,
    step,
    steps: all.map((name) => ({ name, done: done.includes(name) })),
    answers: {
      ...(done.includes("where") ? { where: { choice: "local" } } : {}),
      ...(done.includes("provider") ? { provider: { provider: "anthropic", kind: "anthropic", base_url: null, auth: "api_key" } } : {}),
      ...(done.includes("key") ? { key: { source: "typed" } } : {}),
      ...(done.includes("models") ? { models: { default: "claude-opus-5", cheap: "claude-haiku-4-5" } } : {}),
      ...(done.includes("workspace") ? { workspace: { workspace: "/home/ada/repo", approvals: "ask" } } : {}),
    },
    detected: {
      env: [],
      opencode: { path: "/home/ada/.config/opencode/opencode.jsonc", providers: [], default: null },
      config: { exists: false, path: "/home/ada/.config/troupe/config.yaml", provider: null, base_url: null, api_key_set: false, api_key_source: null, models: {}, usable: false },
      plane: { url: null, linked: false },
    },
    key_storage: { kind: "file", path: "/home/ada/.config/troupe/config.yaml", keychain: false },
    offered: [],
    suggested: { default: null, cheap: null },
    check: null,
    suggested_prompt: null,
    session: null,
    ...extra,
  };
}

const idle = { busy: false, error: null, onBack: null };

/** The page once it says `text`: a render, and a click's re-render, are asynchronous. */
const shown = (text: string): Promise<true> => waitFor(() => says(text) || null, text);

describe("each screen", () => {
  it("Where: two ways, this machine pressed, and the plane's address only for a plane", async () => {
    const onAnswer = vi.fn();
    unmount = render(<Where flow={flowAt("where")} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("Where does the work run?");
    expect(pressed("Use my own machine and keys")).toBe(true);
    expect(document.querySelector('[aria-label="The plane\'s address"]')).toBeNull();
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ choice: "local" });

    button("Sign in to my organisation")!.click();
    const address = await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="The plane\'s address"]'), "the address field");
    type(address, "https://troupe.example/");
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ choice: "plane", plane_url: "https://troupe.example/" });
  });

  it("Provider: the four kinds, what is already here first, and a gateway needs its address", async () => {
    const onAnswer = vi.fn();
    const flow = flowAt("provider");
    flow.detected.config = { ...flow.detected.config, exists: true, provider: "openai", usable: true };
    unmount = render(<Provider flow={flow} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("Which model provider?");

    expect(pressed("A working config.yaml (openai)")).toBe(true);
    for (const kind of ["Anthropic", "OpenAI", "An OpenAI-compatible gateway", "A LiteLLM proxy"]) expect(button(kind)).not.toBeNull();
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ reuse: "config" });

    button("A LiteLLM proxy")!.click();
    const address = await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="Address"]'), "the address field");
    expect(button("Continue")!.disabled).toBe(true);
    type(address, "https://llm-gw.example/v1");
    await waitFor(() => !button("Continue")!.disabled || null, "Continue enabled");
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ provider: "openai", kind: "litellm", base_url: "https://llm-gw.example/v1" });
  });

  it("Key: says where it goes, shows a refusal plainly, and sends a pasted key or the variable's name", async () => {
    const onAnswer = vi.fn();
    const flow = flowAt("key", { check: { state: "refused", reason: "401 unauthorized: the key was refused" } });
    flow.detected.env = ["ANTHROPIC_API_KEY"];
    unmount = render(<Key flow={flow} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("The key");

    expect(says("/home/ada/.config/troupe/config.yaml")).toBe(true);
    expect(says("there is no keychain in this build")).toBe(true);
    expect(says("The provider refused the key: 401 unauthorized: the key was refused. Check it and try again.")).toBe(true);
    expect(pressed("Keep it in ANTHROPIC_API_KEY")).toBe(true);
    button("Check the key and continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ env: "ANTHROPIC_API_KEY" });

    button("Paste it")!.click();
    const key = await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="API key"]'), "the key field");
    expect(button("Check the key and continue")!.disabled).toBe(true);
    type(key, " sk-typed ");
    await waitFor(() => !button("Check the key and continue")!.disabled || null, "the check enabled");
    button("Check the key and continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ api_key: "sk-typed" });
    // Never shown back: the key field is a password field.
    expect(key.getAttribute("type")).toBe("password");
  });

  it("Models: the offer with context and price, the suggestion pressed, and a typed id when nothing is listed", async () => {
    const onAnswer = vi.fn();
    const listed = flowAt("models", {
      offered: [
        { id: "claude-opus-5", context: 200_000, max_output: 64_000, input: 5, output: 25 },
        { id: "claude-haiku-4-5", context: 200_000, max_output: 64_000, input: 1, output: 5 },
      ],
      suggested: { default: "claude-opus-5", cheap: "claude-haiku-4-5" },
      check: { state: "ok", reason: null },
    });
    const first = render(<PickModels flow={listed} {...idle} onAnswer={onAnswer} />);
    await shown("Which models?");
    expect(pressed("claude-opus-5")).toBe(true);
    expect(says("200k tokens of context · $5.00 in, $25.00 out per million tokens")).toBe(true);
    expect((field("Small model") as HTMLSelectElement | HTMLInputElement).value).toBe("claude-haiku-4-5");
    button("claude-haiku-4-5")!.click();
    await waitFor(() => pressed("claude-haiku-4-5") || null, "the small model pressed as the main one");
    button("Save these models and continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ default: "claude-haiku-4-5", cheap: "claude-haiku-4-5" });
    first.unmount();

    const unlisted = flowAt("models", { check: { state: "unknown", reason: "404: no model listing at that URL; check the base URL" } });
    unmount = render(<PickModels flow={unlisted} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("The key could not be confirmed: 404: no model listing at that URL; check the base URL. You can go on and type a model id.");
    expect(button("Save these models and continue")!.disabled).toBe(true);
    type(field("Main model"), "qwen3");
    await waitFor(() => !button("Save these models and continue")!.disabled || null, "saving enabled");
    button("Save these models and continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ default: "qwen3", cheap: null });
  });

  it("Workspace: a directory, the recent ones as chips, and the approval model in two sentences with the safe one pressed", async () => {
    const onAnswer = vi.fn();
    const client = { recentWorkspaces: () => Promise.resolve({ workspaces: [{ path: "/home/ada/repo", last_used_at: null, sessions: 2 }] }) } as unknown as DaemonClient;
    unmount = render(<Workspace flow={flowAt("workspace")} client={client} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("Where is the first project?");

    expect(pressed("Ask me first")).toBe(true);
    expect(says("The agent reads freely, and asks before it writes a file or runs a command.")).toBe(true);
    expect(says("Every write and every command runs as soon as the agent asks for it.")).toBe(true);
    expect(button("Continue")!.disabled).toBe(true);
    const chip = await waitFor(() => button("/home/ada/repo"), "the recent workspace");
    chip.click();
    button("Run everything without asking")!.click();
    await waitFor(() => (pressed("Run everything without asking") && !button("Continue")!.disabled) || null, "the choices taken");
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ workspace: "/home/ada/repo", approvals: "auto" });
  });

  it("Finish: what was set up, the suggested prompt, starting or not, and the plane's way out", async () => {
    const onAnswer = vi.fn();
    const local = flowAt("finish", { suggested_prompt: "Tell me what this project does, how it is built and tested, and where you would start reading." });
    const first = render(<Finish flow={local} {...idle} onAnswer={onAnswer} />);
    await shown("Ready");
    expect(says("Anthropic")).toBe(true);
    expect(says("claude-opus-5 · claude-haiku-4-5 for small work")).toBe(true);
    expect(says("saved in /home/ada/.config/troupe/config.yaml")).toBe(true);
    expect(says("/home/ada/repo")).toBe(true);
    expect(says("the agent asks before it writes or runs anything")).toBe(true);
    expect((field("What to ask first") as HTMLTextAreaElement).value).toBe("Tell me what this project does, how it is built and tested, and where you would start reading.");
    type(field("What to ask first"), "Say hello.");
    await waitFor(() => (field("What to ask first") as HTMLTextAreaElement).value === "Say hello." || null, "the prompt typed");
    button("Start the first session")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ start: true, prompt: "Say hello." });
    button("Finish without starting one")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ start: false });
    first.unmount();

    const plane = flowAt("finish");
    plane.steps = [
      { name: "where", done: true },
      { name: "finish", done: false },
    ];
    plane.answers = { where: { choice: "plane", plane_url: "https://troupe.example" } };
    unmount = render(<Finish flow={plane} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("Sign in next");
    expect(says("https://troupe.example")).toBe(true);
    button("Finish and sign in")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({});
  });
});
