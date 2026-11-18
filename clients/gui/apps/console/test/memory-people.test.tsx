// A person's own memory on Memory (#1096): a platform admin's page lists each person who
// keeps one, with its version, size and when it changed and never its text, and reads one on
// a page of its own, read only, each read a row in the audit naming who read whose and which
// version. A team admin's lists nobody's and reads none; the profiles' documents are listed
// for a platform admin, each linked to its profile's page.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PEOPLE, button, freshBrowser, link, opener, sees, seesButton, startFake, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";

let fake: FakeDeployment;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake(exampleAdmin(), { own: { [PEOPLE.carol.subject]: "I write British English." } });
});

afterEach(async () => {
  close();
  await fake.stop();
});

const { open, close } = opener(() => fake, { openTab: () => undefined });

const people = (): HTMLElement | null => document.querySelector<HTMLElement>('table[aria-label="People\'s own memory"]');
const reads = () => fake.admin.audit.filter((e) => e.action === "memory.read").map((e) => [e.actor, e.subject_id, e.detail?.["version"]]);

describe("people's own memory", () => {
  it("is listed for a platform admin without its text, and read on its own page, each read audited", async () => {
    await open("#/memory", PEOPLE.alice);
    await sees(PEOPLE.carol.subject, people);
    expect(people()!.textContent).not.toContain("British English");
    expect(reads()).toEqual([]);

    link("Read", people()!)!.click();
    await sees("I write British English.");
    await sees("This read is in the audit as memory.read on user/carol@example.com, version 1");
    expect(globalThis.location.hash).toBe(`#/memory/person/${encodeURIComponent(PEOPLE.carol.subject)}`);
    // Read only: nothing on the page changes it.
    expect(document.querySelector("textarea")).toBeNull();
    expect(button("Save")).toBeNull();
    await waitFor(() => reads().length === 1, "the read in the audit");
    expect(reads()).toEqual([[PEOPLE.alice.subject, "user/carol@example.com", 1]]);
  });

  it("records every read, an older version's too", async () => {
    fake.plane.own.clear();
    fake.admin.personal.set(PEOPLE.carol.subject, [
      { version: 1, text: "First.", changed_by: PEOPLE.carol.subject, changed_at: "2026-11-01T09:00:00Z" },
      { version: 2, text: "First.\nSecond.", changed_by: PEOPLE.carol.subject, changed_at: "2026-11-02T09:00:00Z" },
    ]);
    await open(`#/memory/person/${encodeURIComponent(PEOPLE.carol.subject)}`, PEOPLE.alice);
    await sees("Version 2");
    (await seesButton("Read version 1")).click();
    await waitFor(() => reads().length === 2, "the second read in the audit");
    expect(reads()).toEqual([
      [PEOPLE.alice.subject, "user/carol@example.com", 2],
      [PEOPLE.alice.subject, "user/carol@example.com", 1],
    ]);
  });

  it("is nobody's for a team admin, by the page or by its address", async () => {
    await open("#/memory", PEOPLE.bob);
    await waitFor(() => document.querySelector('section[aria-label="The organisation\'s memory"]'), "the organisation's memory");
    expect(people()).toBeNull();
    expect(document.querySelector('section[aria-label="Profiles\' memory"]')).toBeNull();
    close();
    await open(`#/memory/person/${encodeURIComponent(PEOPLE.carol.subject)}`, PEOPLE.bob);
    await waitFor(() => document.querySelector('section[aria-label="The organisation\'s memory"]'), "Memory itself");
    expect(document.body.textContent).not.toContain("British English");
    expect(document.querySelector("h1")?.textContent).toBe("Memory");
    expect(fake.plane.asked.filter((m) => m.startsWith("admin.memory.pe"))).toEqual([]);
  });

  it("lists each profile's for a platform admin, linked to the profile's page where it is edited", async () => {
    await open("#/memory", PEOPLE.alice);
    const profiles = await waitFor(() => document.querySelector<HTMLElement>('table[aria-label="Profiles\' memory"]'), "the profiles' memory");
    const first = profiles.querySelector("tbody a")!;
    expect(first.getAttribute("href")).toMatch(/^#\/profiles\//);
  });
});
