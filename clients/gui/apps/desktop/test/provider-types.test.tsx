// Every provider type where a person picks a provider (troupe #658): the first run's
// provider step and the Models panel offer the types the daemon lists, from the one list
// of them, and each asks only what it needs: no key for Ollama, whose server's address
// may be left to its default, and an address for Azure, which has none of its own. Against
// the fake daemon, which answers as the real one does; an older daemon, which lists no
// types, is offered what it takes.

import { afterEach, describe, expect, it, vi } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import type { SetupFlow, SetupKind, SetupStepName } from "@troupe/client";
import { App } from "../src/App";
import { Key } from "../src/views/Onboarding/Key";
import { Provider } from "../src/views/Onboarding/Provider";
import { FakeDaemon, SETUP_KINDS } from "../../../packages/client/test/support/daemon.js";
import { button, nav, render, says, sees, startOnTheList, type, waitFor } from "./support";

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

function pressed(label: string): boolean {
  return button(label)?.getAttribute("aria-pressed") === "true";
}

function field(label: string): HTMLInputElement | null {
  return document.querySelector<HTMLInputElement>(`[aria-label="${label}"]`);
}

/** Pick an option the way React hears it: through the native setter, then a change event. */
function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

const kinds = SETUP_KINDS as unknown as SetupKind[];

function flowAt(step: SetupStepName, extra: Partial<SetupFlow> = {}): SetupFlow {
  return {
    needed: true,
    completed: null,
    step,
    steps: ["where", "provider", "key", "models", "workspace", "daemon", "finish"].map((name) => ({ name: name as SetupStepName, done: false })),
    answers: { where: { choice: "local" } },
    detected: {
      env: [],
      opencode: { path: "/home/ada/.config/opencode/opencode.jsonc", providers: [], default: null },
      config: { exists: false, path: "/home/ada/.config/troupe/config.yaml", provider: null, base_url: null, api_key_set: false, api_key_source: null, models: {}, usable: false },
      plane: { url: null, linked: false },
    },
    kinds,
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
const shown = (text: string): Promise<true> => waitFor(() => says(text) || null, text);

describe("the first run's provider step", () => {
  it("offers every type the daemon lists, a vendor's variable for each, and asks Azure and Ollama their address", async () => {
    const onAnswer = vi.fn();
    const flow = flowAt("provider");
    flow.detected.env = ["GEMINI_API_KEY"];
    unmount = render(<Provider flow={flow} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("Which model provider?");

    for (const label of ["Anthropic", "OpenAI", "Ollama", "OpenRouter", "Azure OpenAI", "Gemini", "An OpenAI-compatible gateway", "A LiteLLM proxy"]) {
      expect(button(label), label).not.toBeNull();
    }
    // What is already here first: the Gemini key in the environment.
    expect(pressed("GEMINI_API_KEY is set on this computer")).toBe(true);
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ provider: "gemini", kind: "gemini", base_url: null });

    // A vendor asks no address.
    button("OpenRouter")!.click();
    await waitFor(() => pressed("OpenRouter") || null, "OpenRouter pressed");
    expect(field("Address")).toBeNull();

    // Ollama: its server's address, which may be left to its default.
    button("Ollama")!.click();
    const ollama = await waitFor(() => field("Address"), "Ollama's address");
    expect(ollama.placeholder).toBe("http://localhost:11434");
    await sees("leave empty for http://localhost:11434");
    expect(button("Continue")!.disabled).toBe(false);
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({ provider: "ollama", kind: "ollama", base_url: null });

    // Azure: the resource's own address, which it cannot go without.
    button("Azure OpenAI")!.click();
    await waitFor(() => pressed("Azure OpenAI") || null, "Azure pressed");
    const azure = field("Address")!;
    expect(azure.placeholder).toBe("https://<resource>.openai.azure.com");
    expect(button("Continue")!.disabled).toBe(true);
    type(azure, "https://standin.openai.azure.example.test");
    await waitFor(() => !button("Continue")!.disabled || null, "Continue enabled");
    button("Continue")!.click();
    expect(onAnswer).toHaveBeenLastCalledWith({
      provider: "azure_openai",
      kind: "azure_openai",
      base_url: "https://standin.openai.azure.example.test",
    });
  });

  it("asks Azure for its key, with no way to go without one, naming it", async () => {
    const onAnswer = vi.fn();
    const flow = flowAt("key", {
      answers: {
        where: { choice: "local" },
        provider: { provider: "azure_openai", kind: "azure_openai", base_url: "https://standin.openai.azure.example.test", auth: "api_key" },
      },
    });
    unmount = render(<Key flow={flow} {...idle} onAnswer={onAnswer} />).unmount;
    await shown("The key");
    await sees("a real request to Azure OpenAI");
    expect(button("This gateway needs no key")).toBeNull();
    expect(field("API key")).not.toBeNull();
  });

  it("an older daemon, which lists no types, is offered the four ways it takes", async () => {
    const flow = flowAt("provider");
    delete flow.kinds;
    unmount = render(<Provider flow={flow} {...idle} onAnswer={vi.fn()} />).unmount;
    await shown("Which model provider?");
    for (const label of ["Anthropic", "OpenAI", "An OpenAI-compatible gateway", "A LiteLLM proxy"]) expect(button(label), label).not.toBeNull();
    expect(button("Ollama")).toBeNull();
  });
});

describe("a first run with Ollama", () => {
  it("is asked no key: the models the server has come at once, and the file holds none", async () => {
    const fake = await start({ firstRun: true });
    unmount = render(<App />).unmount;

    await waitFor(() => says("Welcome."), "the first run");
    button("Continue")!.click();
    await waitFor(() => says("Where does the work run?"), "the where step");
    button("Continue")!.click();

    await waitFor(() => says("Which model provider?"), "the provider step");
    button("Ollama")!.click();
    await waitFor(() => field("Address"), "Ollama's address");
    button("Continue")!.click();

    // No key step: the models the server has, at once.
    await waitFor(() => says("Which models?"), "the models step");
    expect(says("The key")).toBe(false);
    expect(fake.calls.filter((c) => c.method === "setup.answer").map((c) => c.params["step"])).toEqual(["where", "provider"]);
    expect(pressed("llama3.2:latest")).toBe(true);
    button("Save these models and continue")!.click();

    await waitFor(() => says("Where is the first project?"), "the workspace step");
    expect(fake.settings).toMatchObject({ exists: true, provider: "ollama", base_url: null, api_key: null, models: { default: "llama3.2:latest" } });
  });
});

describe("the Models panel", () => {
  async function openPanel(opts: ConstructorParameters<typeof FakeDaemon>[0] = {}): Promise<HTMLSelectElement> {
    await start(opts);
    startOnTheList();
    unmount = render(<App />).unmount;
    await waitFor(() => nav("This computer"), "the rail");
    nav("This computer")!.click();
    return waitFor(() => document.querySelector<HTMLSelectElement>('select[aria-label="Provider"]'), "the provider choice");
  }

  it("offers every type, and asks each only what it needs", async () => {
    const select = await openPanel();
    expect([...select.options].map((o) => o.value)).toEqual(["anthropic", "openai", "ollama", "openrouter", "azure_openai", "gemini"]);
    expect(field("API key")).not.toBeNull();

    choose(select, "ollama");
    await waitFor(() => says("Ollama takes no key.") || null, "Ollama asking no key");
    expect(field("API key")).toBeNull();
    expect(field("Address")!.placeholder).toBe("http://localhost:11434");

    choose(select, "azure_openai");
    await waitFor(() => field("API key"), "Azure's key");
    expect(field("Address")!.placeholder).toBe("https://<resource>.openai.azure.com");
    await sees("required — your Azure OpenAI resource's own address");
    expect(button("Save")!.disabled).toBe(true);
    type(field("Address")!, "https://standin.openai.azure.example.test");
    await waitFor(() => !button("Save")!.disabled || null, "Save enabled");
  });

  it("from an older daemon, which lists no types, offers what it takes", async () => {
    const select = await openPanel({ servesProviderTypes: false });
    expect([...select.options].map((o) => o.value)).toEqual(["anthropic", "openai"]);
  });
});
