// The rail grouped by where things live (issue #1199): a group for each side the install
// has and none for a side it lacks, a side that is down dimmed with its state beside the
// heading, each side's state said once in the rows at the foot, setup a card until it is
// finished, and Waiting for you's count in the reserved colour only when something waits.
// The rail on its own for each state, then the app, against the fake plane and daemon, for
// the edition read from the install and the fall back to Sessions.

import { afterEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { localSide, onAbsentSide, planeSide, RailBody } from "../src/views/Rail";
import type { RailProps } from "../src/views/Rail";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, sees, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let unmount: (() => void) | null = null;
let harness: Harness | null = null;
let daemon: FakeDaemon | null = null;

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await harness?.stop();
  harness = null;
  await daemon?.stop();
  daemon = null;
});

const connected = localSide({ status: "connected", error: null });
const signedIn = planeSide({ signedIn: true, listError: null, offline: false, expired: false, refused: false });

async function rail(overrides: Partial<RailProps> = {}): Promise<HTMLElement> {
  const props: RailProps = {
    current: "sessions",
    go: () => undefined,
    local: connected,
    plane: signedIn,
    sessions: 12,
    waiting: 0,
    here: 4,
    setup: "finished",
    onLocalRow: () => undefined,
    onPlaneRow: () => undefined,
    me: <div className="me">Ada</div>,
    ...overrides,
  };
  ({ unmount } = render(
    <div className="rail">
      <RailBody {...props} />
    </div>,
  ));
  return waitFor(() => document.querySelector<HTMLElement>(".rail nav") && document.querySelector<HTMLElement>(".rail"), "the rail");
}

const heads = (at: ParentNode): string[] => [...at.querySelectorAll(".rail-head")].map((h) => h.textContent ?? "");
const group = (at: ParentNode, heading: string): HTMLElement | null =>
  [...at.querySelectorAll<HTMLElement>(".rail-group")].find((g) => g.querySelector(".rail-head")?.textContent?.startsWith(heading)) ?? null;
const rows = (at: ParentNode): string[] => [...at.querySelectorAll(".conn button")].map((b) => b.getAttribute("aria-label") ?? "");
const items = (at: ParentNode): string[] => [...at.querySelectorAll("nav button")].map((b) => (b.textContent ?? "").trim());

describe("the rail's groups", () => {
  it("are the work both have, the platform's and this computer's, each side's state in a row at the foot", async () => {
    const at = await rail();
    expect(heads(at)).toEqual(["On the platform", "On this computer"]);
    expect(items(at)).toEqual(["Sessions 12", "Waiting for you", "Review", "Artifacts", "Memory", "Profiles", "Your triggers", "This computer4", "Agents", "Tools and skills", "Appearance", "Setup✓"]);
    expect(rows(at)).toEqual(["This computer: Connected", "Platform: Connected"]);
    expect(at.querySelector(".rail-group.dim")).toBeNull();
  });

  it("draw no group and no row for this computer in a remote-only install", async () => {
    const at = await rail({ local: null });
    expect(heads(at)).toEqual(["On the platform"]);
    expect(nav("This computer")).toBeNull();
    expect(nav("Agents")).toBeNull();
    expect(rows(at)).toEqual(["Platform: Connected"]);
  });

  it("draw no group, no Review and no row for the platform in a local-only install", async () => {
    const at = await rail({ plane: null });
    expect(heads(at)).toEqual(["On this computer"]);
    expect(nav("Review")).toBeNull();
    expect(nav("Profiles")).toBeNull();
    expect(rows(at)).toEqual(["This computer: Connected"]);
  });

  it("dim this computer's group while its daemon is not running, and say so beside the heading and in the row", async () => {
    const at = await rail({ local: localSide({ status: "absent", error: null }) });
    const local = group(at, "On this computer")!;
    expect(local.classList.contains("dim")).toBe(true);
    expect(local.querySelector(".rail-state")?.textContent).toBe("not running");
    expect(local.querySelector(".rail-state")?.classList.contains("down")).toBe(true);
    // Its items still open; the count of its sessions goes with the connection.
    // at once: the rail is drawn
    expect(button("This computer", local)?.textContent).toBe("This computer");
    expect(rows(at)).toContain("This computer: Not running");
    expect(group(at, "On the platform")!.classList.contains("dim")).toBe(false);
  });

  it("say a daemon being looked for as starting, in amber", async () => {
    const at = await rail({ local: localSide({ status: "searching", error: null }) });
    expect(group(at, "On this computer")!.querySelector(".rail-state.busy")?.textContent).toBe("starting…");
    expect(rows(at)).toContain("This computer: Starting…");
  });

  it("dim the platform's group while it is offline, and say which offline in the row's title", async () => {
    const offline = planeSide({ signedIn: false, listError: null, offline: true, expired: false, refused: false });
    const at = await rail({ plane: offline });
    const plane = group(at, "On the platform")!;
    expect(plane.classList.contains("dim")).toBe(true);
    expect(plane.querySelector(".rail-state")?.textContent).toBe("offline");
    expect(rows(at)).toContain("Platform: Offline");
    expect(at.querySelector('.conn button[aria-label="Platform: Offline"]')?.getAttribute("title")).toBe("the platform is not answering");
    expect(planeSide({ signedIn: false, listError: null, offline: true, expired: true, refused: false }).why).toBe("the platform is answering again, and this sign-in has ended");
    expect(planeSide({ signedIn: false, listError: null, offline: false, expired: false, refused: true }).why).toBe("the platform needs a newer version of this app");
    // Signed in, a list the plane did not answer is a reconnect on its way.
    expect(planeSide({ signedIn: true, listError: "502", offline: false, expired: false, refused: false }).word).toBe("Reconnecting…");
  });

  it("open each row's page", async () => {
    const went: string[] = [];
    const at = await rail({ onLocalRow: () => went.push("local"), onPlaneRow: () => went.push("plane") });
    for (const b of at.querySelectorAll<HTMLButtonElement>(".conn button")) b.click();
    expect(went).toEqual(["local", "plane"]);
  });

  it("count what is waiting in the reserved colour only when something is", async () => {
    let at = await rail({ waiting: 0 });
    // at once: the rail is drawn
    expect(button("Waiting for you", at)?.querySelector(".count")).toBeNull();
    unmount?.();
    at = await rail({ waiting: 3 });
    const count = button("Waiting for you", at)!.querySelector(".count")!;
    expect(count.classList.contains("hot")).toBe(true);
    expect(count.textContent).toBe("3");
    // at once: the rail is drawn
    expect(button("Sessions", at)!.querySelector(".count")!.classList.contains("hot")).toBe(false);
  });

  it("carry unfinished setup as a card at the top, and finished setup as an item with a check", async () => {
    const went: string[] = [];
    let at = await rail({ setup: { done: 2, of: 5, next: "Models" }, go: (s) => went.push(s) });
    const card = at.querySelector<HTMLButtonElement>(".setup-card")!;
    expect(at.firstElementChild).toBe(card);
    expect(card.textContent).toBe("Finish setup 2 of 5Next: Models");
    expect([...card.querySelectorAll(".bar i")].map((i) => i.className)).toEqual(["on", "on", "", "", ""]);
    expect(nav("Setup")).toBeNull();
    card.click();
    expect(went).toEqual(["setup"]);
    unmount?.();
    at = await rail({ setup: "finished" });
    expect(at.querySelector(".setup-card")).toBeNull();
    // at once: the rail is drawn
    expect(button("Setup", at.querySelector(".rail-foot")!)?.querySelector(".check")?.textContent).toBe("✓");
  });

  it("send a screen of a side the install does not have to Sessions, and leave every other alone", () => {
    expect(onAbsentSide("profiles", { local: true, plane: false })).toBe(true);
    expect(onAbsentSide("review", { local: true, plane: false })).toBe(true);
    for (const screen of ["local", "agents", "connect"]) expect(onAbsentSide(screen, { local: false, plane: true })).toBe(true);
    for (const screen of ["sessions", "approvals", "artifacts", "memory", "appearance", "setup", "session", "new"]) {
      expect(onAbsentSide(screen, { local: false, plane: false })).toBe(false);
    }
    expect(onAbsentSide("profiles", { local: false, plane: true })).toBe(false);
    expect(onAbsentSide("agents", { local: true, plane: false })).toBe(false);
  });
});

describe("the app's rail", () => {
  async function signedInToAPlane(): Promise<void> {
    localStorage.clear();
    startOnTheList();
    harness = await startHarness();
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  }

  it("is remote only in a browser told of no daemon: no group, no row and no page of this computer's", async () => {
    await signedInToAPlane();
    unmount = render(<App />).unmount;
    await waitFor(() => rows(document).includes("Platform: Connected"), "the platform connected");
    expect(heads(document)).toEqual(["On the platform"]);
    expect(rows(document)).toEqual(["Platform: Connected"]);
    expect(nav("This computer")).toBeNull();
    expect(nav("Agents")).toBeNull();
    // at once: the rail is drawn with the row waited for above
    expect(nav("Review")).not.toBeNull();
    expect(document.querySelector(".me .name")?.textContent).toBe("Alice");
    // Setup is still reachable, and says how to add this computer rather than send the person to a page that is not there.
    nav("Setup")!.click();
    await sees("troupe-daemon open");
    expect(document.querySelector("main")?.textContent).not.toContain("Connect it on This computer");
  });

  it("keeps a daemon let go of as a side that is down until the next load, its page still there", async () => {
    await signedInToAPlane();
    daemon = new FakeDaemon({ osUser: "alice" });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => rows(document).includes("This computer: Connected") && rows(document).includes("Platform: Connected"), "both sides connected");
    nav("This computer")!.click();
    (await waitFor(() => [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === "Disconnect") ?? null, "Disconnect")).click();
    await waitFor(() => rows(document).includes("This computer: Not running"), "this computer down");
    expect(group(document, "On this computer")?.querySelector(".rail-state")?.textContent).toBe("not running");
    expect(nav("This computer")?.getAttribute("aria-current")).toBe("page");
  });

  it("is local only under Local only, with finished setup at the foot", async () => {
    localStorage.clear();
    startOnTheList();
    localStorage.setItem("troupe.pref.localOnly", "yes");
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => rows(document).includes("This computer: Connected"), "this computer connected");
    expect(heads(document)).toEqual(["On this computer"]);
    expect(nav("Review")).toBeNull();
    expect(rows(document)).toEqual(["This computer: Connected"]);
    // The daemon's first run is done, so Setup is at the foot with its check.
    await waitFor(() => nav("Setup")?.querySelector(".check"), "Setup, finished");
    // The connection is the rows' to say, not the signed-in block's.
    expect(document.querySelector(".me")?.textContent).not.toMatch(/local only|not connected/);
  });

  it("carries setup's real steps on a plane when this computer's daemon has not been set up", async () => {
    await signedInToAPlane();
    daemon = new FakeDaemon({ osUser: "alice", firstRun: true });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    const card = await waitFor(() => document.querySelector<HTMLElement>(".rail .setup-card"), "the setup card");
    await sees("Finish setup 0 of 7", card);
    await sees("Next: Where", card);
    expect(nav("Setup")).toBeNull();
  });
});
