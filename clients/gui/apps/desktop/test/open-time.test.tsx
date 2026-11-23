// How long a long session takes to open (troupe #1182): about 10,000 events (a thousand
// turns, each a person's line, three file reads of 4 KB and an answer), from the press on
// its row to its last answer on screen, once for a session that never compacted and once
// for one that did. Measured, not asserted: it prints what it took, so a change to the open
// can be compared on one machine. Run alone with TROUPE_OPEN_TIME=1.

import { afterEach, beforeEach, describe, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { longSession } from "../../../packages/client/test/support/long.js";
import { render, says, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
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

describe.skipIf(!process.env["TROUPE_OPEN_TIME"])("opening a long session", () => {
  for (const compactAt of [undefined, 950]) {
    it(`prints how long it takes to show its last answer${compactAt ? ", from its checkpoint" : ""}`, async () => {
      const session = daemon.seed("/home/ada/long");
      longSession(session.log, 1000, compactAt ? { compactAt } : {});

      unmount = render(<App />).unmount;
      const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/ada/long")), "the row");
      const t0 = performance.now();
      row.click();
      await waitFor(() => says("answer 999"), "the last answer", 120_000);
      const ms = performance.now() - t0;
      console.log(`OPEN-TIME ${session.log.headSeq} events${compactAt ? " from a checkpoint" : ""}: ${Math.round(ms)} ms, ${document.querySelectorAll(".stream *").length} elements`);
    }, 180_000);
  }
});
