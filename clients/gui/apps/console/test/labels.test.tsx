// What a screen reader hears for each of the console's fields: the words of its label, and
// not its placeholder, which disappears once something is typed and which many readers do
// not announce. A field's hint describes it (`aria-describedby`) rather than being run
// into its name. Checked across every form the console draws, opened the way a person
// opens it.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, freshBrowser, render, says, signedInAs, startFake, visit, waitFor } from "./support";
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

type Control = HTMLInputElement | HTMLSelectElement;

/** A control's accessible name, as the name computation reaches it for a form field. */
function nameOf(el: Control): string {
  const label = el.getAttribute("aria-label");
  if (label) return label.trim();
  const by = el.getAttribute("aria-labelledby");
  if (by) return by.split(/\s+/).map((id) => document.getElementById(id)?.textContent ?? "").join(" ").trim();
  return [...(el.labels ?? [])]
    .map((l) => {
      const copy = l.cloneNode(true) as HTMLElement;
      copy.querySelectorAll("input, select, textarea").forEach((c) => c.remove());
      return copy.textContent ?? "";
    })
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Every field on the screen now that is named wrongly, said as what is wrong with it. */
function misnamed(): string[] {
  const controls = [...document.querySelectorAll<Control>("input:not([type=hidden]), select")];
  expect(controls.length).toBeGreaterThan(0);
  return controls.flatMap((el) => {
    const name = nameOf(el);
    const placeholder = el.getAttribute("placeholder") ?? "";
    const what = `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ""} (${name || placeholder || "nothing"})`;
    if (!name) return [`${what} has no name but its placeholder`];
    if (placeholder && name === placeholder) return [`${what} is named by its placeholder`];
    const hints = [...(el.labels ?? [])].flatMap((l) => [...l.querySelectorAll(".hint")]);
    if (hints.length) return [`${what} has its hint run into its name`];
    return [];
  });
}

async function check(where: string, open: () => Promise<unknown>): Promise<string[]> {
  await open();
  return misnamed().map((m) => `${where}: ${m}`);
}

describe("the console's fields", () => {
  it("are named by their labels on every form, not by a placeholder, with hints as descriptions", async () => {
    const found: string[] = [];

    found.push(...(await check("sign-in", async () => {
      unmount = render(<App navigate={() => undefined} />).unmount;
      await waitFor(() => button("Sign in"), "the sign-in screen");
    })));
    unmount?.();

    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams");
    unmount = render(<App />).unmount;
    found.push(...(await check("teams, enabling a group", async () => {
      (await waitFor(() => button("Enable a group as a team"), "the team list")).click();
      await waitFor(() => says("Team name"), "the form");
    })));

    visit("#/teams/core/members");
    found.push(...(await check("members, linking a group", async () => {
      (await waitFor(() => button("Link a group"), "the members tab")).click();
      await waitFor(() => document.querySelector("select"), "the form");
    })));

    visit("#/teams/core/access");
    found.push(...(await check("access, granting a profile", async () => {
      (await waitFor(() => button("Grant a profile"), "the access tab")).click();
      await waitFor(() => says("Team volume"), "the form");
    })));

    visit("#/teams/core/admins");
    found.push(...(await check("admins, naming one", async () => {
      (await waitFor(() => button("Name an administrator"), "the admins tab")).click();
      await waitFor(() => says("Subject"), "the form");
    })));

    visit("#/teams/core/limits");
    found.push(...(await check("limits", async () => {
      (await waitFor(() => button("Change core's limits"), "the limits")).click();
      await waitFor(() => says("Idle before it goes dormant") && document.querySelector("form.edit"), "the form");
    })));

    visit("#/teams/core/danger");
    found.push(...(await check("danger zone, its typed confirmation", async () => {
      (await waitFor(() => button("Remove core"), "the danger zone")).click();
      await waitFor(() => says("Type core to confirm"), "the confirmation");
    })));

    visit("#/clients");
    found.push(...(await check("client versions", async () => {
      const terminal = await waitFor(() => document.querySelector<HTMLElement>('section.card[aria-label="The terminal"]'), "the policy");
      button("Change", terminal)!.click();
      await waitFor(() => says("Minimum"), "the form");
    })));

    visit("#/organisation");
    found.push(...(await check("the organisation's enforced set", async () => {
      (await waitFor(() => button("Change the enforced set"), "the enforced set")).click();
      await waitFor(() => document.querySelector(".enforced form"), "the form");
    })));

    visit("#/sessions");
    found.push(...(await check("sessions' filters", async () => {
      await waitFor(() => document.querySelector("table.sessions"), "the sessions");
    })));

    visit("#/audit");
    found.push(...(await check("the audit's filters", async () => {
      await waitFor(() => document.querySelector("table.audit"), "the audit");
    })));

    expect(found).toEqual([]);
  });
});
