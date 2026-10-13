// Client versions: per component, the recommended version, the minimum and the blocked
// list, through `admin.clients.get` and `admin.clients.put`. A change is previewed, field
// by field and in words, before it is sent; the plane's refusal is shown where it was
// made, with nothing written; and what the audit recorded is shown once it is applied.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
  visit("#/clients");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const card = (name: string): HTMLElement | null => document.querySelector<HTMLElement>(`section.card[aria-label="${name}"]`);

describe("client versions", () => {
  it("shows each component's policy as the plane holds it", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    expect(says("0.16.0-beta", terminal)).toBe(true);
    expect(says("0.14.0-beta", terminal)).toBe(true);
    expect(says("0.15.0-beta", terminal)).toBe(true);
    expect(says("last set by alice@example.com", terminal)).toBe(true);
    expect(says("never set", card("The daemon")!)).toBe(true);
    expect(card("The desktop app")).not.toBeNull();
  });

  it("previews a raised minimum, applies it on confirm, and shows what the audit recorded", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    button("Change", terminal)!.click();
    type(await waitFor(() => field("Minimum", terminal), "the form"), "0.16.0-beta");
    button("Preview", terminal)!.click();

    await waitFor(() => says("What will happen", terminal), "the preview");
    expect(says("minimum: 0.14.0-beta", terminal)).toBe(true);
    expect(says("minimum: 0.16.0-beta", terminal)).toBe(true);
    expect(says("Every troupe older than 0.16.0-beta is refused when it next connects, and told to run troupe update.", terminal)).toBe(true);
    // Nothing is sent until it is confirmed.
    expect(fake.admin.policies["tui"]!.minimum).toBe("0.14.0-beta");

    button("Apply", terminal)!.click();
    await waitFor(() => says("Recorded in the audit as clients.put on tui"), "the audit's note");
    expect(fake.admin.policies["tui"]!.minimum).toBe("0.16.0-beta");
    expect(fake.admin.audit.at(-1)).toMatchObject({ actor: "alice@example.com", action: "clients.put", subject_id: "tui", detail: { minimum: { from: "0.14.0-beta", to: "0.16.0-beta" } } });
    expect(says("version policy is applied")).toBe(true);
    await waitFor(() => !says("What will happen") && says("0.16.0-beta", card("The terminal")!), "the policy, as it now is");
  });

  it("shows the plane's refusal where it was made, and writes nothing", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    button("Change", terminal)!.click();
    type(await waitFor(() => field("Minimum", terminal), "the form"), "0.17.0-beta");
    button("Preview", terminal)!.click();
    (await waitFor(() => button("Apply", terminal), "the preview")).click();

    await waitFor(() => says("minimum: the minimum 0.17.0-beta is newer than the recommended version 0.16.0-beta", terminal), "the refusal");
    expect(fake.admin.policies["tui"]!.minimum).toBe("0.14.0-beta");
    expect(fake.admin.audit).toEqual([]);
  });

  it("lets a team admin read the policy and change none of it", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    expect(says("0.14.0-beta", terminal)).toBe(true);
    expect(button("Change", terminal)).toBeNull();
    expect(says("Only a platform admin changes these")).toBe(true);
  });

  it("says when there is no policy at all", async () => {
    fake.admin.policies["tui"] = { recommended: null, minimum: null, blocked: [], updated_by: null, updated_at: null };
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("No policy yet"), "the empty state");
    expect(says("This plane serves every version of every client.")).toBe(true);
  });
});
