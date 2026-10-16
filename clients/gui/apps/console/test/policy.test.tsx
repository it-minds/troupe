// Policy and settings: every platform setting with where its value came from, changed and
// reset by a platform admin and read by a team admin, the admin group saved only behind a
// passed check, and the ladder, against the fake plane's `admin.settings.list`,
// `admin.setting.put`, `.reset`, `.effective` and `admin.identity.check`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
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

async function open(who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit("#/policy");
  unmount = render(<App />).unmount;
}

const row = (key: string): HTMLElement | null => document.querySelector<HTMLElement>(`.row[aria-label="${key}"]`);
const ladderRow = (key: string): HTMLTableRowElement | null => [...document.querySelectorAll<HTMLTableRowElement>('section[aria-label="The ladder"] tbody tr')].find((r) => r.cells[0]?.textContent === key) ?? null;

describe("the settings", () => {
  it("are listed by panel with where each value came from, the deployment's read-only and a secret never shown", async () => {
    await open();
    await waitFor(() => row("platform_admin_group"), "the settings");
    await sees("Who administers this platform");
    await sees("from the deployment", row("platform_admin_group")!);
    await sees("changed here", row("default_erase_after_days")!);
    // The deployment's: read, with why it is not changed here, and nothing to press.
    await sees("The deployment's: changed in the deployment and rolled", row("base_url")!);
    expect(button("Change", row("base_url")!)).toBeNull();
    expect(says("set · never shown", row("breakglass_token")!) || says("not set", row("breakglass_token")!)).toBe(true);
    // The two panels with screens of their own are pointed at, not drawn twice.
    expect(row("client_provider")).toBeNull();
    expect(row("issuer")).toBeNull();
    expect(document.querySelector('a[href="#/organisation"]')).not.toBeNull();
    expect(document.querySelector('a[href="#/signin"]')).not.toBeNull();
  });

  it("is changed and reset behind a preview, each shown as the audit recorded it", async () => {
    await open();
    button("Change", await waitFor(() => row("default_idle_timeout_seconds"), "the setting"))!.click();
    type(await waitFor(() => field("default_idle_timeout_seconds"), "the field"), "900");
    button("Preview", row("default_idle_timeout_seconds")!)!.click();
    await waitFor(() => says("What will happen", row("default_idle_timeout_seconds")!), "the preview");
    button("Apply", row("default_idle_timeout_seconds")!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on default_idle_timeout_seconds"), "the audit's note");
    expect(fake.admin.stored.get("default_idle_timeout_seconds")).toBe(900);

    button("Reset", await waitFor(() => row("default_erase_after_days") && button("Reset", row("default_erase_after_days")!) && row("default_erase_after_days"), "the reset"))!.click();
    await waitFor(() => says("It goes back to what the plane was deployed with.", row("default_erase_after_days")!), "the reset's preview");
    button("Reset", row("default_erase_after_days")!.querySelector(".preview")!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.reset on default_erase_after_days"), "the audit's note");
    expect(fake.admin.stored.has("default_erase_after_days")).toBe(false);
  });

  it("is read by a team admin, who is offered nothing to change", async () => {
    await open(PEOPLE.bob);
    await waitFor(() => row("platform_admin_group"), "the settings");
    await sees("Read-only for you");
    expect(button("Change")).toBeNull();
    expect(button("Reset")).toBeNull();
  });
});

describe("the group that decides who administers", () => {
  it("is saved only once the check has passed for the value in the field", async () => {
    await open();
    button("Change", await waitFor(() => row("platform_admin_group"), "the setting"))!.click();
    const value = await waitFor(() => field("platform_admin_group"), "the field");
    type(value, "nobody-carries-this");
    await waitFor(() => says("Run the check before saving this one"), "the gate");
    const preview = () => button("Preview", row("platform_admin_group")!)!;
    expect(preview().disabled).toBe(true);
    button("Run the check", row("platform_admin_group")!)!.click();
    await waitFor(() => says("nobody-carries-this has never arrived in the groups claim"), "the failed check");
    expect(preview().disabled).toBe(true);

    type(value, "grp-core");
    // A check for another value does not count for this one.
    expect(preview().disabled).toBe(true);
    button("Run the check", row("platform_admin_group")!)!.click();
    await waitFor(() => says("3 person/people known here carry grp-core in the groups claim, including you."), "the passed check");
    await waitFor(() => !preview().disabled, "the save unlocked");
    preview().click();
    button("Apply", await waitFor(() => row("platform_admin_group")!.querySelector(".preview") && row("platform_admin_group"), "the preview"))!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on platform_admin_group"), "the audit's note");
    expect(fake.admin.stored.get("platform_admin_group")).toBe("grp-core");
  });
});

describe("the ladder", () => {
  it("names the rung that decided each value and every opinion, above every team and for one", async () => {
    await open();
    const erase = await waitFor(() => ladderRow("default_erase_after_days"), "the ladder");
    await sees("the platform: what no team may exceed", erase);
    await sees("deployment 365", erase);
    await sees("platform 180 (in force)", erase);

    type(field("As one team sees it")!, "core");
    await waitFor(() => says("team 90", ladderRow("default_erase_after_days")!), "core's own opinion");
    await sees("team 90 (in force)", ladderRow("default_erase_after_days")!);
  });
});
