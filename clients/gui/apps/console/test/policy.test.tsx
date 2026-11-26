// Policy and settings: every platform setting with where its value came from, changed and
// reset by a platform admin and read by a team admin, the admin group saved only behind a
// passed check, and the ladder, against the fake plane's `admin.settings.list`,
// `admin.setting.put`, `.reset`, `.effective` and `admin.identity.check`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PEOPLE, button, field, freshBrowser, opener, says, sees, startFake, type, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  close();
  await fake.stop();
});

const { open, close } = opener(() => fake);

const row = (key: string): HTMLElement | null => document.querySelector<HTMLElement>(`.row[aria-label="${key}"]`);
const ladderRow = (key: string): HTMLTableRowElement | null =>
  [...document.querySelectorAll<HTMLTableRowElement>('section[aria-label="The ladder"] tbody tr')].find((r) => r.cells[0]?.querySelector("code")?.textContent === key) ?? null;

describe("the settings", () => {
  it("are listed by panel with where each value came from, the deployment's read-only and a secret never shown", async () => {
    await open("#/policy");
    await waitFor(() => row("platform_admin_group"), "the settings");
    await sees("Who administers this platform");
    await sees("from the deployment", () => row("platform_admin_group"));
    await sees("changed here", () => row("default_erase_after_days"));
    // The deployment's: read, with why it is not changed here, and nothing to press.
    await sees("The deployment's: changed in the deployment and rolled", () => row("base_url"));
    expect(button("Change", row("base_url")!)).toBeNull();
    expect(says("set · never shown", row("breakglass_token")!) || says("not set", row("breakglass_token")!)).toBe(true);
    // The two panels with screens of their own are pointed at, not drawn twice.
    expect(row("client_provider")).toBeNull();
    expect(row("issuer")).toBeNull();
    expect(document.querySelector('a[href="#/organisation"]')).not.toBeNull();
    expect(document.querySelector('a[href="#/signin"]')).not.toBeNull();
  });

  it("is changed and reset behind a preview, each shown as the audit recorded it", async () => {
    await open("#/policy");
    button("Change", await waitFor(() => row("default_idle_timeout_seconds"), "the setting"))!.click();
    // Asked in minutes, the plane's seconds converted on the way out.
    type(await waitFor(() => field("Idle before a session goes to sleep"), "the field"), "15");
    button("Preview", row("default_idle_timeout_seconds")!)!.click();
    await waitFor(() => says("What will happen", row("default_idle_timeout_seconds")!), "the preview");
    await sees("Idle before a session goes to sleep: 15 min", () => row("default_idle_timeout_seconds"));
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
    await open("#/policy", PEOPLE.bob);
    await waitFor(() => row("platform_admin_group"), "the settings");
    await sees("Read-only for you");
    expect(button("Change")).toBeNull();
    expect(button("Reset")).toBeNull();
  });
});

describe("a setting in its unit", () => {
  it("is named by its label, with its key under it, and its value read in the unit", async () => {
    fake.admin.stored.set("platform_budget_micros", 500_000_000);
    await open("#/policy");
    const budget = await waitFor(() => row("platform_budget_micros"), "the setting");
    expect(budget.querySelector(".name")?.textContent).toBe("Budget for the platform");
    expect(budget.querySelector("code.key")?.textContent).toBe("platform_budget_micros");
    await sees("$500.00", budget);
    await sees("30 min", () => row("default_idle_timeout_seconds"));
    await sees("180 days", () => row("default_erase_after_days"));
    await sees("24 hours", () => row("throwaway_erase_after_hours"));
    await sees("monthly, from the 1st (UTC)", () => row("default_budget_period"));
    await sees("on", () => row("pins_allowed"));
  });

  it("asks for money in dollars, previews and records the change in dollars, and sends millionths", async () => {
    fake.admin.stored.set("platform_budget_micros", 500_000_000);
    await open("#/policy");
    button("Change", await waitFor(() => row("platform_budget_micros"), "the setting"))!.click();
    const amount = await waitFor(() => field("Budget for the platform"), "the dollars field");
    expect(amount.value).toBe("500");
    await sees("In dollars.", () => row("platform_budget_micros"));

    // Not an amount: said at the field, and nothing to preview.
    type(amount, "lots");
    await sees("An amount in dollars, like 500 or 12.50.", () => row("platform_budget_micros"));
    expect(button("Preview", row("platform_budget_micros")!)!.disabled).toBe(true); // at once: drawn with the refusal seen above

    type(amount, "750");
    button("Preview", row("platform_budget_micros")!)!.click();
    await waitFor(() => says("What will happen", row("platform_budget_micros")!), "the preview");
    await sees("Budget for the platform: $500.00", () => row("platform_budget_micros"));
    await sees("Budget for the platform: $750.00", () => row("platform_budget_micros"));
    expect(says("750000000", row("platform_budget_micros")!)).toBe(false); // at once: the preview is drawn, and holds no millionths

    button("Apply", row("platform_budget_micros")!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on platform_budget_micros"), "the audit's note");
    const note = document.querySelector<HTMLElement>(".audit-note")!;
    await sees("Budget for the platform", note);
    await sees("$500.00 → $750.00", note);
    expect(fake.admin.stored.get("platform_budget_micros")).toBe(750_000_000);
  });

  it("asks for hours in hours, and previews the change in them", async () => {
    await open("#/policy");
    button("Change", await waitFor(() => row("throwaway_erase_after_hours"), "the setting"))!.click();
    const hours = await waitFor(() => field("Erase a throwaway session after"), "the hours field");
    await sees("In hours.", () => row("throwaway_erase_after_hours"));
    type(hours, "6");
    button("Preview", row("throwaway_erase_after_hours")!)!.click();
    await sees("Erase a throwaway session after: 6 hours", () => row("throwaway_erase_after_hours"));
  });

  it("asks for a switch as on or off, and a choice by its words", async () => {
    await open("#/policy");
    button("Change", await waitFor(() => row("default_budget_period"), "the setting"))!.click();
    const period = (await waitFor(() => field("A new team's budget counted over"), "the choice")) as HTMLSelectElement;
    expect([...period.options].map((o) => o.textContent)).toEqual(["monthly, from the 1st (UTC)", "never turns over"]);
    button("Cancel", row("default_budget_period")!)!.click();

    button("Change", await waitFor(() => row("pins_allowed") && button("Change", row("pins_allowed")!) && row("pins_allowed"), "the switch"))!.click();
    const pins = (await waitFor(() => field("Members may pin a session"), "the switch's field")) as HTMLSelectElement;
    expect([...pins.options].map((o) => o.textContent)).toEqual(["on", "off"]);
    type(pins, "false");
    button("Preview", row("pins_allowed")!)!.click();
    await sees("Members may pin a session: off", () => row("pins_allowed"));
  });

  it("falls back to the key and a text field on a plane that names no setting", async () => {
    fake.admin.named = false;
    await open("#/policy");
    const idle = await waitFor(() => row("default_idle_timeout_seconds"), "the setting");
    expect(idle.querySelector(".name")).toBeNull();
    await sees("1800", idle);
    button("Change", idle)!.click();
    type(await waitFor(() => field("default_idle_timeout_seconds"), "the key's field"), "900");
    button("Preview", row("default_idle_timeout_seconds")!)!.click();
    await sees("default_idle_timeout_seconds: 900", () => row("default_idle_timeout_seconds"));
    button("Apply", row("default_idle_timeout_seconds")!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on default_idle_timeout_seconds"), "the audit's note");
    expect(fake.admin.stored.get("default_idle_timeout_seconds")).toBe(900);
  });
});

describe("the group that decides who administers", () => {
  it("is saved only once the check has passed for the value in the field", async () => {
    await open("#/policy");
    button("Change", await waitFor(() => row("platform_admin_group"), "the setting"))!.click();
    const value = await waitFor(() => field("Group that administers the platform"), "the field");
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
    await waitFor(() => says("3 people known here carry grp-core in the groups claim, including you."), "the passed check");
    await waitFor(() => !preview().disabled, "the save unlocked");
    preview().click();
    button("Apply", await waitFor(() => row("platform_admin_group")!.querySelector(".preview") && row("platform_admin_group"), "the preview"))!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on platform_admin_group"), "the audit's note");
    expect(fake.admin.stored.get("platform_admin_group")).toBe("grp-core");
  });
});

describe("the ladder", () => {
  it("names the rung that decided each value and every opinion, above every team and for one", async () => {
    await open("#/policy");
    const erase = await waitFor(() => ladderRow("default_erase_after_days"), "the ladder");
    await sees("the platform: what no team may exceed", erase);
    await sees("Erase a session after", erase);
    await sees("deployment 365 days", erase);
    await sees("platform 180 days (in force)", erase);
    await sees("30 min", () => ladderRow("default_idle_timeout_seconds"));

    type(field("As one team sees it")!, "core");
    await waitFor(() => says("team 90 days", ladderRow("default_erase_after_days")!), "core's own opinion");
    await sees("team 90 days (in force)", () => ladderRow("default_erase_after_days"));
  });
});
