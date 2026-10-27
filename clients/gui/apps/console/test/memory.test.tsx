// Company memory (#55): the organisation's and each team's memory document, and a worker
// profile's on the profile's page, through `admin.memory.*`. A change is previewed line by
// line against the version in force, saved on confirm, and shown as the audit recorded it;
// every version opens onto what it changed. A team admin changes their team's and reads the
// organisation's.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { writtenBy } from "../src/views/Memory";
import { PEOPLE, button, freshBrowser, render, says, sees, seesButton, seesField, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const card = (title: string): HTMLElement | null => document.querySelector<HTMLElement>(`section.memory[aria-label="${title}"]`);

describe("company memory", () => {
  it("shows the organisation's memory with its version, previews a change line by line, saves it on confirm and shows the audit", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    await sees("We deploy on Tuesdays.", org);
    await sees("Version 2, saved", org);

    (await seesButton("Change the organisation's memory", org()!)).click();
    const text = await seesField("The organisation's memory", org()!);
    type(text, "We deploy on Tuesdays.\nThe on-call rota is in the wiki.\nFreeze on the last week of December.");
    await sees("bytes", org);
    button("Preview", org()!)!.click();

    await sees("What will happen", org);
    await sees("Freeze on the last week of December.", org);
    await sees("organisation v2 → v3", org);
    await sees("Every session on this plane's pods reads it from its next turn", org);
    // Nothing is written until it is confirmed.
    expect(fake.admin.memory.get("organisation")!.length).toBe(2);

    (await seesButton("Save", org()!)).click();
    await sees("Recorded in the audit as memory.put on organisation", org);
    await sees("Version 3, saved", org);
    expect(fake.admin.memory.get("organisation")!.at(-1)!.text).toBe("We deploy on Tuesdays.\nThe on-call rota is in the wiki.\nFreeze on the last week of December.");
    expect(fake.admin.audit.at(-1)!).toMatchObject({ action: "memory.put", subject_id: "organisation", detail: { version: { from: 2, to: 3 } } });
  });

  it("opens a version onto what it changed against the one before", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    (await seesButton("Version 2", org()!)).click();
    await sees("organisation v1 → v2", org);
    const added = await waitFor(() => org()?.querySelector(".memory-version .add"), "the line version 2 added");
    expect(added.textContent).toContain("The on-call rota is in the wiki.");
  });

  // #55's provenance: blame, not history, in a column beside each line.
  it("says who wrote each line, beside it", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    (await seesButton("Who wrote each line", org()!)).click();
    const table = await waitFor(() => org()?.querySelector<HTMLTableElement>("table.blame-lines"), "who wrote each line");
    const rows = [...table.querySelectorAll("tr")].map((r) => [r.querySelector("th")!.textContent, r.querySelector("td")!.textContent]);
    expect(rows).toEqual([
      ["v1 alice@example.com", "We deploy on Tuesdays."],
      ["v2 alice@example.com", "The on-call rota is in the wiki."],
    ]);
    expect(table.querySelector("th")!.getAttribute("title")).toContain("by alice@example.com");
    (await seesButton("Hide who wrote each line", org()!)).click();
    await waitFor(() => !org()?.querySelector("table.blame-lines"), "the column folded away");

    // An agent's entry, in a person's own, names the agent and the session it came from.
    expect(writtenBy({ text: "- Tabs.", version: 3, by: "ada@example.com", session: "20261025T101112-abc123", agent: "build" })).toBe(
      "v3 build in 20261025T101112-abc123",
    );
  });

  // Memory as entries: the document's `## Topic` sections as the plane reads them, read only.
  it("lists the version shown as its entries, one per topic, and edits only the document", async () => {
    fake.admin.memory.get("organisation")!.push({ version: 3, text: "Opening words.\n\n## Tone\n\nPlain English.", changed_by: "alice@example.com", changed_at: "2026-10-26T09:00:00Z" });
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    (await seesButton("Its entries, one per topic (2)", org()!)).click();
    const table = await waitFor(() => org()?.querySelector<HTMLTableElement>('table[aria-label="Entries of organisation v3"]'), "the entries");
    expect([...table.querySelectorAll("tr")].map((r) => [r.querySelector("th")!.textContent, r.querySelector("td")!.textContent])).toEqual([
      ["General", "v3 alice@example.com · used in 0 sessions"],
      ["Tone", "v3 alice@example.com · used in 0 sessions"],
    ]);
    expect(table.querySelector("input, textarea, button")).toBeNull();
  });

  it("says when somebody else saved first, and saves nothing", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    (await seesButton("Change the organisation's memory", org()!)).click();
    type(await seesField("The organisation's memory", org()!), "Mine.");
    button("Preview", org()!)!.click();
    await sees("What will happen", org);

    // Somebody else's save lands while the preview is open.
    fake.admin.memory.get("organisation")!.push({ version: 3, text: "Theirs.", changed_by: "dan@example.com", changed_at: "2026-10-18T10:00:00Z" });
    (await seesButton("Save", org()!)).click();
    await sees("version 3 is in force now", org);
    expect(fake.admin.memory.get("organisation")!.at(-1)!.text).toBe("Theirs.");
  });

  it("lets a team admin change their team's and only read the organisation's", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    const design = () => card("The design team's memory");
    await sees("We deploy on Tuesdays.", org);
    await sees("Only a platform admin changes it.", org);
    expect(button("Change the organisation's memory", org()!)).toBeNull();
    // Another team's is not listed for them.
    expect(card("The core team's memory")).toBeNull();

    await sees("Nothing written yet", design);
    (await seesButton("Change the design team's memory", design()!)).click();
    type(await seesField("The design team's memory", design()!), "Use the design tokens.");
    button("Preview", design()!)!.click();
    await sees("no other team's session reads it", design);
    (await seesButton("Save", design()!)).click();
    await sees("Recorded in the audit as memory.put on team/design", design);
    expect(fake.admin.memory.get("team/design")!.map((v) => v.text)).toEqual(["Use the design tokens."]);
  });

  it("holds a document to its limit before anything is asked", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    (await seesButton("Change the organisation's memory", org()!)).click();
    type(await seesField("The organisation's memory", org()!), "x".repeat(8193));
    await sees("At most 8192 bytes.", org);
    expect((await seesButton("Preview", org()!)).disabled).toBe(true);
  });

  it("edits a worker profile's memory on the profile's page", async () => {
    visit("#/profiles/dev");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const dev = () => card("The dev profile's memory");
    await waitFor(dev, "the dev profile's memory");
    await sees("Nothing written yet", dev);
    (await seesButton("Change the dev profile's memory", dev()!)).click();
    type(await seesField("The dev profile's memory", dev()!), "Fix one issue at a time.");
    button("Preview", dev()!)!.click();
    await sees("Every session on dev's pods, and on the pods of every profile that extends it, reads it from its next turn.", dev);
    (await seesButton("Save", dev()!)).click();
    await sees("Recorded in the audit as memory.put on profile/dev", dev);
    await sees("Fix one issue at a time.", dev);
    expect(fake.admin.memory.get("profile/dev")!.map((v) => v.text)).toEqual(["Fix one issue at a time."]);
  });

  // Who is behind: each running session the document reaches, with the version
  // its last turn ran under; a pod's is nudged, a machine's hears at its next poll.
  it("lists the running sessions behind the version in force, and nudges a pod's", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    await sees("1 running session behind version 2", org);
    const readers = () => org()?.querySelector<HTMLElement>('section.readers[aria-label="Who reads it"]') ?? null;
    await sees("s-7f3a9c21", readers);
    await sees("v1 · behind", readers);
    await sees("laptop-9b1d (a person's machine)", readers);
    await sees("on a person's machine hears at its daemon's next poll", readers);

    (await seesButton("Nudge s-7f3a9c21", readers()!)).click();
    await sees("Told s-7f3a9c21 again; it reads version 2 at its next turn.", readers);
    expect(fake.admin.memoryNudged).toEqual(["s-7f3a9c21"]);

    // The preview names the same sessions.
    (await seesButton("Change the organisation's memory", org()!)).click();
    type(await seesField("The organisation's memory", org()!), "We deploy on Thursdays.");
    button("Preview", org()!)!.click();
    await sees("2 running sessions read it now; 1 of them is behind version 2.", org);
  });

  it("sets two versions side by side, and rolls back to one as a new version with the audit's note", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const org = () => card("The organisation's memory");
    await waitFor(org, "the organisation's memory");
    (await seesButton("Version 1", org()!)).click();
    (await seesButton("Beside version 2", org()!)).click();

    const table = await waitFor(() => org()?.querySelector<HTMLTableElement>("table.side-by-side"), "the two versions side by side");
    const head = [...table.querySelectorAll("th")].map((th) => th.textContent);
    expect(head).toEqual(["Version 1", "Version 2"]);
    const added = table.querySelector("td.add");
    expect(added?.textContent).toContain("The on-call rota is in the wiki.");
    expect(table.querySelector("td.empty")).not.toBeNull();

    (await seesButton("Restore version 1", org()!)).click();
    await sees("What will happen", org);
    await sees("Saved as version 3, with the text of version 1; every version stays.", org);
    expect(fake.admin.memory.get("organisation")!.length).toBe(2);

    (await seesButton("Roll back", org()!)).click();
    await sees("Recorded in the audit as memory.put on organisation", org);
    await sees("rolled back to v1", org);
    await sees("Version 3, saved", org);
    expect(fake.admin.memory.get("organisation")!.at(-1)!.text).toBe("We deploy on Tuesdays.");
    expect(fake.admin.audit.at(-1)!).toMatchObject({ action: "memory.put", detail: { rolled_back_to: 1, note: "rolled back to v1" } });
  });

  // Slice 2: a profile that extends another shows, above its own, the memory its sessions
  // read first from the profiles it extends, each saying which profile it is from.
  it("shows on a profile's page the memory it has from the profile it extends, and where it came from", async () => {
    const dev = fake.admin.profiles.find((p) => p.name === "dev")!;
    fake.admin.profiles.push({ ...dev, name: "base", extends: null });
    dev.extends = "base";
    fake.admin.memory.set("profile/base", [{ version: 2, text: "Every pod: sign every commit.", changed_by: "root@example.test", changed_at: "2026-10-20T09:00:00Z" }]);

    visit("#/profiles/dev");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const card_ = () => card("The dev profile's memory");
    await waitFor(card_, "the dev profile's memory");
    await sees("From the base profile: version 2", card_);
    await sees("Every pod: sign every commit.", card_);
    await sees("Changed on base's page.", card_);
    await sees("Nothing written yet", card_);
  });
});
