// Company memory (#55): the organisation's and each team's memory document, and a worker
// profile's on the profile's page, through `admin.memory.*`. A change is previewed line by
// line against the version in force, saved on confirm, and shown as the audit recorded it;
// every version opens onto what it changed. A team admin changes their team's and reads the
// organisation's.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
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
    await sees("Every session on this plane's pods reads it from its next activation", org);
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
    await sees("Every session on dev's pods reads it from its next activation.", dev);
    (await seesButton("Save", dev()!)).click();
    await sees("Recorded in the audit as memory.put on profile/dev", dev);
    await sees("Fix one issue at a time.", dev);
    expect(fake.admin.memory.get("profile/dev")!.map((v) => v.text)).toEqual(["Fix one issue at a time."]);
  });
});
