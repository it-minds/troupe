// A button that waits on one reply gives the person a way back when the reply never comes
// (troupe #739's follow-up, D131): every call to the daemon has a stated wait, and past it
// the call rejects with a sentence, so the screen says it and offers the button again. The
// Models panel's Save is the one here; approvals, questions, sign-in's link and the first
// run's answers wait on their call the same way.

import { afterEach, describe, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { callTimeouts } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, nav, render, sees, seesButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;
const defaultMs = callTimeouts.defaultMs;

afterEach(async () => {
  callTimeouts.defaultMs = defaultMs;
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon?.stop();
  daemon = null;
});

function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

describe("the Models panel's Save, whose answer never comes", () => {
  it("says the daemon did not answer in time and offers Save again", async () => {
    localStorage.clear();
    localStorage.setItem("troupe.pref.localOnly", "yes");
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    startOnTheList();
    unmount = render(<App />).unmount;
    await waitFor(() => nav("This computer"), "the rail");
    nav("This computer")!.click();
    const select = await waitFor(() => document.querySelector<HTMLSelectElement>('select[aria-label="Provider"]'), "the provider choice");

    choose(select, "ollama");
    await sees("Ollama takes no key.");
    type(await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="Address"]'), "the address field"), "http://localhost:11434");

    callTimeouts.defaultMs = 400;
    daemon.loseReply["config.set"] = "hold";
    (await seesButton("Save")).click();
    await seesButton("Saving…");

    await sees("No answer to config.set in 1 second. It may still have been done; look again before trying once more.");
    await waitFor(() => (button("Save") && !button("Save")!.disabled) || null, "Save offered again");
  });
});
