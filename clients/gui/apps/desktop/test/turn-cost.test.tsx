// What a turn cost (issue #389, troupe-remote Decision 769). The event that ends a turn
// carries `turn`, and the session draws one line under the turn from it, in the words the
// terminal client uses: its calls, what was sent, what the cache served, what came back,
// and the money. The call that wrote a compaction's summary is the session's spend too.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

const usage = { input_tokens: 500, cache_read: 1_000, cache_write: 0, output_tokens: 1 };

describe("what a turn cost", () => {
  it("is one line under the turn once it ends, and the session's cost so far counts the summariser's call", async () => {
    startOnTheList();
    const session = daemon.seed("/home/ada/costly");
    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/ada/costly")),
      "the session in the list",
    );
    row.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");

    session.log.append("user_input", { source: "user", text: "go" }, { kind: "user", subject: "ada" });
    for (const text of ["Looking.", "Done."]) {
      session.log.append("llm_response", { message: { role: "assistant", content: [{ type: "text", text }] }, usage, gateway: { cost_micros: 10_000 } });
    }
    await waitFor(() => [...document.querySelectorAll(".stream .turn.agent")].some((a) => a.textContent?.includes("Done.")), "the answer");
    // Nothing is said while the turn runs.
    expect(document.querySelector(".stream .note.turn-cost")).toBeNull();

    session.log.append("compacted", {
      summary: "the gist",
      reason: "threshold",
      model: "cheap",
      usage: { input_tokens: 100, cache_read: 0, cache_write: 0, output_tokens: 40 },
      gateway: { cost_micros: 10_000 },
    });
    session.log.append("turn_ended", { turn: { calls: 3, input_tokens: 1_100, cache_read: 2_000, cache_write: 0, output_tokens: 42, cost_micros: 30_000, unpriced: 0 } });

    const line = await waitFor(() => document.querySelector(".stream .note.turn-cost"), "the turn's line");
    expect(line.textContent).toBe("turn: 3 calls · ↑ 1.1k sent · 2.0k cached · ↓ 42 received · $0.03");
    expect(line.previousElementSibling?.textContent).toBe("conversation compacted");

    // The two answers and the summary, not the answers alone.
    const facts = [...document.querySelectorAll(".backstage dt")].find((dt) => dt.textContent === "Cost so far");
    const cost = facts?.nextElementSibling?.querySelector(".when");
    expect(cost?.getAttribute("title")).toBe("30000 micros");
    expect(cost?.textContent).toBe("$0.03");
  });
});
