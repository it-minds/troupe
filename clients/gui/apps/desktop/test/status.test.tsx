// What a row's state reads as (issue #52, part 2): a session doing nothing is `idle`,
// its own status with no colour, so `queued` can keep the comp's amber for a held
// message; and a session whose only open question is the workspace's trust question,
// asked at its start before the agent has done a thing, reads as waiting for you — in
// the list, and in the launcher's count.

import { afterEach, describe, expect, it } from "vitest";
import type { FleetRow } from "@troupe/client";
import { Launcher } from "../src/views/Launcher";
import { statusOf } from "../src/views/bits";
import { button, render, says, waitFor } from "./support";

function row(overrides: Partial<FleetRow> = {}): FleetRow {
  return {
    id: "s-1",
    kind: "local",
    source: "daemon",
    title: "Regnskabsafstemning Q3",
    profile: "build",
    owner: null,
    state: "active",
    status: "idle",
    doneReason: null,
    pendingApprovals: 0,
    pendingQuestions: 0,
    costMicros: null,
    lastActiveAt: new Date(Date.now() - 41 * 60_000).toISOString(),
    pinned: false,
    yourRole: null,
    origin: null,
    reviewedBy: null,
    sync: null,
    raw: null,
    ...overrides,
  };
}

let unmount: (() => void) | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
});

describe("a row's status", () => {
  it("is idle, not queued, when the session is doing nothing", () => {
    expect(statusOf(row())).toBe("idle");
    expect(statusOf(row({ status: null, state: "active" }))).toBe("idle");
  });

  it("is waiting when the trust question is the only thing open, whatever the agent is doing", () => {
    // The daemon's row says `waiting` once a question is open; the count alone is enough too.
    expect(statusOf(row({ status: "idle", pendingQuestions: 1 }))).toBe("waiting");
    expect(statusOf(row({ status: "waiting", pendingQuestions: 1 }))).toBe("waiting");
    expect(statusOf(row({ status: "thinking", pendingQuestions: 1 }))).toBe("waiting");
  });

  it("keeps the rest as they were", () => {
    expect(statusOf(row({ status: "acting" }))).toBe("running");
    expect(statusOf(row({ state: "dormant", status: null }))).toBe("dormant");
    expect(statusOf(row({ state: "read_only" }))).toBe("readonly");
    expect(statusOf(row({ doneReason: "llm_error" }))).toBe("error");
  });
});

describe("the launcher", () => {
  it("counts what is waiting, names where the recent ones run, and leads to the three screens", async () => {
    const went: string[] = [];
    const rows = [
      row({ id: "s-1", title: "Regnskabsafstemning Q3", pendingQuestions: 1, status: "waiting" }),
      row({ id: "s-2", title: "Tilbud til Kolding Kommune", kind: "team", source: "plane" }),
      row({ id: "s-3", title: "Ryd op i kundelisten", status: "acting" }),
      row({ id: "s-4", title: "Mine noter", state: "dormant", status: null }),
    ];
    ({ unmount } = render(
      <Launcher
        rows={rows}
        auth={null}
        daemon={{ status: "connected", user: { subject: "ada", name: "ada" } }}
        planeUrl=""
        offline={false}
        localOnly
        onNew={() => went.push("new")}
        onSessions={() => went.push("sessions")}
        onApprovals={() => went.push("approvals")}
        onSettings={() => went.push("local")}
        onOpen={(id) => went.push(`open:${id}`)}
      />,
    ));

    await waitFor(() => says("1 waiting for you"), "the launcher");
    expect(says("The oldest stopped 41 min ago.")).toBe(true);
    expect(says("3 on this computer")).toBe(true);
    // Not signed in to a platform, so the platform's count is not a count of anything.
    expect(says("on the platform")).toBe(false);
    // The three most recent, in the list's order, each saying where it runs.
    expect(says("Regnskabsafstemning Q3")).toBe(true);
    expect(says("Tilbud til Kolding Kommune")).toBe(true);
    expect(says("Ryd op i kundelisten")).toBe(true);
    expect(says("Mine noter")).toBe(false);
    expect(document.querySelector(".recent .is-waiting")).not.toBeNull();
    expect(says("daemon connected")).toBe(true);
    expect(says("local only")).toBe(true);

    button("01")!.click();
    button("02")!.click();
    button("03")!.click();
    button("Settings")!.click();
    [...document.querySelectorAll<HTMLButtonElement>(".recent button")][1]!.click();
    expect(went).toEqual(["new", "sessions", "approvals", "local", "open:s-2"]);
  });

  it("says nothing is waiting without the reserved colour", async () => {
    ({ unmount } = render(
      <Launcher
        rows={[row()]}
        auth={null}
        daemon={{ status: "absent", user: null }}
        planeUrl=""
        offline={false}
        localOnly={false}
        onNew={() => undefined}
        onSessions={() => undefined}
        onApprovals={() => undefined}
        onSettings={() => undefined}
        onOpen={() => undefined}
      />,
    ));
    await waitFor(() => says("Nothing waiting"), "the launcher");
    expect(document.querySelector(".tile.needs")).toBeNull();
    expect(says("daemon not running")).toBe(true);
    expect(says("not signed in")).toBe(true);
  });
});
