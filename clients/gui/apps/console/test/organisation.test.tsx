// The organisation's document: its defaults, below each person's own settings, and its
// enforced set, above everything a person sets, both through `admin.settings.list` and
// `admin.setting.put`. The keys the enforced set may hold are the plane's list, not this
// console's: a key the plane adds is offered with nothing changed here.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { ENFORCEABLE } from "../../../packages/client/test/support/admin.js";
import { PEOPLE, button, field, freshBrowser, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
  visit("#/organisation");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const enforced = (): HTMLElement | null => document.querySelector<HTMLElement>(".enforced");
const row = (key: string): HTMLElement | null => document.querySelector<HTMLElement>(`.row[aria-label="${key}"]`);

describe("the organisation's document", () => {
  it("shows the defaults with where each came from, and the enforced set against the keys the plane lists", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => enforced(), "the enforced set");

    expect(says("openai", row("client_provider")!)).toBe(true);
    expect(says("deployed", row("client_provider")!)).toBe(true);
    expect(says("glm-5.2", row("client_model_default")!)).toBe(true);
    expect(says("set here", row("client_model_default")!)).toBe(true);
    expect(says("unset", row("client_model_expensive")!)).toBe(true);

    const keys = [...enforced()!.querySelectorAll("tbody tr td:first-child")].map((td) => td.textContent);
    expect(keys).toEqual(ENFORCEABLE.map((k) => k.key));
    expect(says("200", enforced()!)).toBe(true);
    expect(says("the most it may be", enforced()!)).toBe(true);
  });

  it("offers a key the plane lists that this console has never heard of", async () => {
    fake.admin.enforceable = [...ENFORCEABLE, { key: "max_cost_micros", kind: "ceiling", meaning: "the most it may be", type: "integer", min: 0 }];
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => enforced() && says("max_cost_micros", enforced()!), "the plane's new key");

    button("Change the enforced set")!.click();
    type(await waitFor(() => field("max_cost_micros", enforced()!), "its field"), "5000000");
    button("Preview", enforced()!)!.click();
    (await waitFor(() => button("Apply", enforced()!), "the preview")).click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_enforced"), "the audit's note");
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200, max_cost_micros: 5_000_000 });
  });

  it("previews a lower ceiling in words, applies it on confirm, and shows the audit's diff", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the enforced set"), "the enforced set")).click();
    type(await waitFor(() => field("max_turns", enforced()!), "the form"), "50");
    type(field("approvals", enforced()!)!, "deny");
    button("Preview", enforced()!)!.click();

    await waitFor(() => says("What will happen", enforced()!), "the preview");
    expect(says("No machine may set max_turns above 50; a lower value stays.", enforced()!)).toBe(true);
    expect(says("No machine may loosen approvals past deny; a tighter value stays.", enforced()!)).toBe(true);
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200 });

    button("Apply", enforced()!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_enforced"), "the audit's note");
    expect(says("client_enforced.max_turns")).toBe(true);
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "deny", max_turns: 50 });
    expect(fake.admin.audit.at(-1)!.detail).toEqual({
      "client_enforced.approvals": { from: "wait", to: "deny" },
      "client_enforced.max_turns": { from: 200, to: 50 },
    });
  });

  it("changes a default and resets one, each previewed and recorded", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const cheap = await waitFor(() => row("client_model_cheap"), "the defaults");
    button("Change", cheap)!.click();
    type(await waitFor(() => field("client_model_cheap", cheap), "the field"), "qwen3.6-35b");
    button("Preview", cheap)!.click();
    await waitFor(() => says("A person's own settings file still wins over a default.", cheap), "the preview");
    button("Apply", cheap)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_model_cheap"), "the audit's note");
    expect(fake.admin.stored.get("client_model_cheap")).toBe("qwen3.6-35b");

    const model = await waitFor(() => row("client_model_default") && button("Reset", row("client_model_default")!) && row("client_model_default"), "the stored default");
    button("Reset", model!)!.click();
    await waitFor(() => says("It goes back to what the plane was deployed with.", row("client_model_default")!), "the reset's preview");
    button("Reset", row("client_model_default")!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.reset on client_model_default"), "the reset's note");
    expect(fake.admin.stored.has("client_model_default")).toBe(false);
  });

  it("shows a plane's refusal of the set where it was made", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the enforced set"), "the enforced set")).click();
    type(await waitFor(() => field("max_depth", enforced()!), "the form"), "lots");
    button("Preview", enforced()!)!.click();
    (await waitFor(() => button("Apply", enforced()!), "the preview")).click();
    await waitFor(() => says("max_depth must be a whole number", enforced()!), "the refusal");
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200 });
  });

  it("lets a team admin read the document and change none of it", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => enforced(), "the enforced set");
    expect(button("Change the enforced set")).toBeNull();
    expect(button("Change", row("client_provider")!)).toBeNull();
    expect(says("Only a platform admin changes the organisation's document.")).toBe(true);
  });

  it("shows the set as stored on a plane that does not list its keys", async () => {
    fake.admin.enforceable = null;
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("This plane does not list the keys it may enforce"), "the older plane's set");
    expect(says('"max_turns": 200')).toBe(true);
    expect(button("Change the enforced set")).toBeNull();
  });
});
