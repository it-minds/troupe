// `/compact` in the desktop app: the palette asks the daemon to compact the session's
// conversation now (`session.compact`), says so, and the transcript says the conversation
// was compacted as asked; a refusal, a turn running or too little to compact, is the
// daemon's own sentence. Driven against the fake daemon.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { sees, sessionOpener, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;

async function command(line: string): Promise<void> {
  if (!document.querySelector(".palette")) document.querySelector<HTMLButtonElement>('.composer button[aria-label="Commands"]')!.click();
  const field = await waitFor(() => document.querySelector<HTMLInputElement>('.palette input[aria-label="Command"]'), "the commands");
  type(field, line);
  await waitFor(() => document.querySelector('.palette .row[aria-selected="true"] .name')?.textContent === `/${line.split(" ")[0]}`, `the /${line} row`);
  field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
}

const { open, close } = sessionOpener(() => daemon);

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  close();
  location.hash = "";
  await daemon.stop();
});

describe("/compact", () => {
  it("asks the daemon to compact now, says so, and the transcript says it was as asked", async () => {
    const session = daemon.seed("/home/ada/release");
    await open("/home/ada/release");

    await command("compact");
    const call = await waitFor(() => daemon.calls.find((c) => c.method === "session.compact"), "session.compact");
    expect(call.params["session_id"]).toBe(session.id);
    expect(typeof call.params["command_id"]).toBe("string");
    await sees("compacting the conversation");
    await sees("conversation compacted, as asked with /compact");
  });

  it("shows the daemon's reason when it refuses", async () => {
    daemon.seed("/home/ada/release");
    daemon.compactRefusal = "there is too little to compact yet: a compaction keeps the last few messages as they are, and there is nothing before them to summarise";
    await open("/home/ada/release");

    await command("compact");
    await waitFor(() => daemon.calls.some((c) => c.method === "session.compact"), "session.compact");
    await sees("not compacted: there is too little to compact yet");
  });
});
