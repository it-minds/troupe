// Who reads an artifact, in the console (troupe #1238): its page has the one menu its owner
// changes it from, as the desktop app's Access tab does. The teams granted the profile its
// session ran on first and the owner's other teams after, as checkboxes; the people it is
// shared with by name at their roles, and a picker that finds the people that profile covers
// too; the organisation switch; one Save, which makes no version and says what changed. A
// team the owner may not give it to is refused in place with the draft kept, and a change
// from a sensitive session that waits on a team administrator says so. An administrator's
// table of every artifact says the teams that read each.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PEOPLE, freshBrowser, opener, sees, seesButton, startFake, type, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";

const carol = { subject: PEOPLE.carol.subject, display_name: "Carol" };
const gil = { subject: "gil@example.com", display_name: "Gil", email: "gil@example.com" };

let fake: FakeDeployment;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake(exampleAdmin(), {
    profileTeams: { clinic: ["clinics", "billing"] },
    profilePeople: { clinic: [gil] },
    artifacts: [
      artifact("art-clinic", carol, { title: "Clinic figures", visibility: "private", teams: ["clinics"], origin: { session_id: "s-1", profile: "clinic", agent: "root", where: "pod" } }),
      artifact("art-other", { subject: "ada@example.com", display_name: "Ada" }, { title: "Ada's page", visibility: "organisation" }),
    ],
  });
});

afterEach(async () => {
  close();
  await fake.stop();
});

const { open, close } = opener(() => fake, { openTab: () => undefined });

const menu = (): HTMLElement | null => document.querySelector<HTMLElement>('section[aria-label="Who reads it"]');
const box = (label: string): HTMLInputElement | null => [...(menu()?.querySelectorAll<HTMLLabelElement>("label") ?? [])].find((l) => l.textContent?.trim().startsWith(label))?.querySelector("input") ?? null;

describe("who reads an artifact, in the console", () => {
  it("is one menu on its owner's page: the profile's teams first, a person found through its profile, the organisation switch, one Save and no version", async () => {
    await open("#/artifacts/art-clinic", PEOPLE.carol);
    await sees("It is read by the clinics team.", menu);
    await waitFor(() => [...menu()!.querySelectorAll(".teams label")].map((l) => l.textContent?.split(" · ")[0]?.trim()).join() === "The clinics team,The billing team,The core team", "the profile's teams first, then the owner's");
    expect(box("The clinics team")!.checked).toBe(true);
    expect(box("The billing team")!.checked).toBe(false);

    box("The billing team")!.click();
    box("The whole organisation")!.click();
    type((await waitFor(() => menu()!.querySelector<HTMLInputElement>('input[placeholder="A name or an email"]'), "the picker")), "gi");
    (await seesButton("Add Gil · gil@example.com", menu()!)).click();
    await sees("Not saved yet: added the billing team and Gil; the whole organisation reads it.", menu);
    (await seesButton("Save who reads it", menu()!)).click();
    await sees("Saved: added the billing team and Gil; the whole organisation reads it.");
    const a = fake.plane.artifacts.get("art-clinic")!;
    expect(a.teams).toEqual(["clinics", "billing"]);
    expect(a.visibility).toBe("organisation");
    expect(fake.plane.named.get("art-clinic")?.get(gil.subject)?.role).toBe("view");
    expect(a.versions).toHaveLength(1);
  });

  it("refuses a team the owner may not give it to in place, keeping the draft, and changes nothing", async () => {
    await open("#/artifacts/art-clinic", PEOPLE.carol);
    await waitFor(() => box("The billing team"), "the menu");
    // The grant gone since the menu was read: the plane refuses that team.
    (fake.plane as unknown as { opts: { profileTeams: Record<string, string[]> } }).opts.profileTeams = { clinic: ["clinics"] };
    box("The billing team")!.click();
    (await seesButton("Save who reads it", menu()!)).click();
    await sees("Not saved: you may not give it to team billing", menu);
    expect(box("The billing team")!.checked).toBe(true);
    expect(fake.plane.artifacts.get("art-clinic")!.teams).toEqual(["clinics"]);
  });

  it("says a change from a sensitive session waits on a team administrator", async () => {
    fake.plane.artifacts.set("art-clinic", { ...fake.plane.artifacts.get("art-clinic")!, sharing: "ask" });
    await open("#/artifacts/art-clinic", PEOPLE.carol);
    (await waitFor(() => box("The core team"), "the menu")).click();
    (await seesButton("Save who reads it", menu()!)).click();
    await sees("Not changed yet: This session is sensitive, so sharing it wider is waiting on a team administrator", menu);
    expect(fake.plane.artifacts.get("art-clinic")!.teams).toEqual(["clinics"]);
  });

  it("is not offered on somebody else's, and an administrator's table says the teams that read each", async () => {
    await open("#/artifacts/art-other", PEOPLE.carol);
    await sees("Ada's page");
    expect(menu()).toBeNull();
    close();
    await open("#/artifacts", PEOPLE.alice);
    const row = await waitFor(() => [...document.querySelectorAll<HTMLTableRowElement>("tbody tr")].find((r) => r.cells[0]?.textContent?.startsWith("Clinic figures")) ?? null, "the clinic row");
    expect(row.textContent).toContain("the clinics team");
  });
});
