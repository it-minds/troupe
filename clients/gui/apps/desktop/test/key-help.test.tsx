// Where a key comes from, in the organisation's words, beside the key field on This
// computer: an address as a link, a sentence as it was written, nothing where the plane
// says nothing; and "Use my organisation" says when the organisation hands a key out.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { GATEWAY_DEFAULTS } from "../../../packages/client/test/support/plane.js";
import { button, nav, render, says, sees, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness | null = null;
let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;

const code = (): HTMLElement | null => document.querySelector<HTMLElement>(".usercode");
const keyHelp = (): HTMLElement | null => document.querySelector<HTMLElement>('[data-testid="key-help"]');

/** Signed in to a plane whose `me.client_defaults` is `defaults`, with the daemon on this computer found. */
async function signedInWith(defaults: Record<string, unknown>): Promise<void> {
  harness = await startHarness({ plane: { clientDefaults: defaults } });
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  const found = async () => ({ transport: "ws" as const, port: daemon!.port, token: daemon!.token });
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device", findDaemon: found, readDaemon: found };
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.start", "sessions");
  localStorage.setItem("troupe.pref.appearance.chosen.ada@example.com", "yes");
  unmount = render(<App />).unmount;
  (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
  await waitFor(code, "the code to enter");
  harness.idp.approve("ada@example.com", "Ada");
  await waitFor(() => nav("This computer"), "the rail");
  nav("This computer")!.click();
  await waitFor(() => says("Models"), "the Models panel");
}

beforeEach(() => {
  localStorage.clear();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  delete window.troupe;
  await daemon?.stop();
  daemon = null;
  await harness?.stop();
  harness = null;
});

describe("where a key comes from, in the organisation's words", () => {
  it("is a link beside the key field when it is an address", async () => {
    await signedInWith({ ...GATEWAY_DEFAULTS, key_help: "https://llm-gw.example/keys" });
    const help = await waitFor(keyHelp, "the organisation's word on the key");
    await sees("Where a key comes from, says your organisation");
    const link = help.querySelector("a");
    expect(link?.getAttribute("href")).toBe("https://llm-gw.example/keys");
    expect(link?.textContent).toBe("https://llm-gw.example/keys");
  });

  it("is said as written when it is a sentence, and the organisation's key is said when it hands one out", async () => {
    await signedInWith({ ...GATEWAY_DEFAULTS, key_help: "open a ticket at the helpdesk", defaults: { provider: "openai", api_key: "sk-everybody" } });
    await sees("open a ticket at the helpdesk");
    expect(keyHelp()?.querySelector("a")).toBeNull();

    (await waitFor(() => button("Use organisation defaults"), "the organisation's fill")).click();
    await sees("which hands out a key: save, and sessions use it unless you paste your own");
  });

  it("says nothing where the plane says nothing", async () => {
    await signedInWith(GATEWAY_DEFAULTS);
    await waitFor(() => button("Use organisation defaults"), "the organisation's fill");
    expect(keyHelp()).toBeNull();
  });
});
