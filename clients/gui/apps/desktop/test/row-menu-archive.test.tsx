// A session row's ⋯ archives it, as the session's own ⋯ does (troupe #1116): offered where
// the list was given a way to archive, on the rows the person owns; under the Archived
// filter it puts the session back; and a refusal is said in the list, not in a dialog.
// The list rendered alone, its way to archive a recorder.

import { afterEach, describe, expect, it } from "vitest";
import { ErrorCodes, TroupeRpcError } from "@troupe/client";
import type { FleetRow } from "@troupe/client";
import type { Archived } from "../src/hooks";
import { Sessions } from "../src/views/Sessions";
import { button, render, sees, seesButton, waitFor } from "./support";

let unmount: (() => void) | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
});

function row(overrides: Partial<FleetRow>): FleetRow {
  return {
    id: "s-1",
    kind: "local",
    source: "daemon",
    title: "Ledger",
    profile: "build",
    owner: null,
    state: "active",
    status: "idle",
    doneReason: null,
    pendingApprovals: 0,
    pendingQuestions: 0,
    costMicros: null,
    lastActiveAt: new Date(Date.now() - 5 * 60_000).toISOString(),
    pinned: false,
    yourRole: "owner",
    origin: null,
    reviewedBy: null,
    sync: null,
    raw: null,
    ...overrides,
  };
}

/** A way to archive that records each call, and refuses where `refuse` says. */
function archiving(rows: FleetRow[], refuse?: unknown): Archived & { calls: [string, boolean][] } {
  const calls: [string, boolean][] = [];
  return {
    rows,
    loading: false,
    error: null,
    load: async () => undefined,
    set: async (r, on) => {
      calls.push([r.id, on]);
      if (refuse) throw refuse;
    },
    calls,
  };
}

const entry = (text: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === text);

async function rowMenu(text: string): Promise<HTMLElement> {
  (await waitFor(() => entry(text)?.querySelector<HTMLButtonElement>(".row-menu button.ib"), `the ⋯ beside ${text}`)).click();
  return waitFor(() => {
    const pop = entry(text)?.querySelector<HTMLElement>(".row-menu .menu-pop");
    return pop && !pop.hidden && pop;
  }, `the ⋯ menu beside ${text}`);
}

function list(rows: FleetRow[], archived?: Archived): void {
  unmount = render(
    <Sessions rows={rows} loading={false} error={null} onOpen={() => undefined} onStart={() => undefined} archived={archived} />,
  ).unmount;
}

function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

describe("a session row's ⋯ and archiving", () => {
  it("offers nothing to archive where the list was given no way to", async () => {
    list([row({})]);
    await waitFor(() => entry("Ledger"), "the row");
    expect(entry("Ledger")!.querySelector(".row-menu")).toBeNull();
  });

  it("offers Archive session on the owner's row, with the session menu's line, and archives it", async () => {
    const archived = archiving([]);
    list([row({}), row({ id: "s-2", title: "Notes", yourRole: "collaborator" })], archived);

    const pop = await rowMenu("Ledger");
    expect(pop.textContent).toContain("Hide it from the session list, for everyone who sees it");
    (await seesButton("Archive session", pop)).click();
    await waitFor(() => archived.calls.length === 1, "the archive asked for");
    expect(archived.calls).toEqual([["s-1", true]]);
    // Somebody else's session is not the person's to hide.
    expect(entry("Notes")!.querySelector(".row-menu")).toBeNull();
  });

  it("offers Unarchive session on a row under Archived, and puts it back", async () => {
    const archived = archiving([row({ archived: true })]);
    list([], archived);

    choose(await waitFor(() => document.querySelector<HTMLSelectElement>('select[aria-label="Archived"]'), "the Archived filter"), "archived");
    const pop = await rowMenu("Ledger");
    expect(button("Archive session", pop)).toBeNull();
    expect(pop.textContent).toContain("Put it back in the session list");
    (await seesButton("Unarchive session", pop)).click();
    await waitFor(() => archived.calls.length === 1, "the unarchive asked for");
    expect(archived.calls).toEqual([["s-1", false]]);
  });

  it("says a refusal in the list, in words, and opens no dialog", async () => {
    const refusal = new TroupeRpcError("session.archive", { code: ErrorCodes.forbidden, message: "forbidden" });
    list([row({})], archiving([], refusal));

    (await seesButton("Archive session", await rowMenu("Ledger"))).click();
    await sees("It was not archived. Only its owner can archive this session.");
    expect(document.querySelector('.banner.error[role="alert"]')?.textContent).toBe("It was not archived. Only its owner can archive this session.");
    expect(document.querySelector('[role="dialog"], [role="alertdialog"]')).toBeNull();
  });
});
