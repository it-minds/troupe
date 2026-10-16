// Sign-in: the identity provider, checked before it is saved, saved anyway only when asked,
// reset to the deployment's; and the SCIM connector's token shown once, its switch, and its
// token forgotten only once the base URL is typed. Against the fake plane's
// `admin.provider.*` and `admin.scim.*`, with the plane's two roles.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
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
  visit("#/signin");
  unmount = render(<App />).unmount;
}

const sso = (): HTMLElement => document.querySelector<HTMLElement>('[aria-label="Single sign-on"]')!;
const scim = (): HTMLElement => document.querySelector<HTMLElement>('[aria-label="SCIM connector"]')!;
const go = (verb: string) => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith(verb) && !b.disabled);

describe("the identity provider", () => {
  it("says what the registration needs, every value with where it came from, and a secret as set", async () => {
    await open();
    await waitFor(() => says("Single sign-on") && says("https://troupe.example.com/admin/callback"), "the provider");
    expect(says("https://idp.example.com", sso())).toBe(true);
    expect(says("set · never shown", sso())).toBe(true);
    expect(says("deployed-client-secret")).toBe(false);
  });

  it("checks the values in the form, refuses a save the provider does not stand behind, and saves it anyway when told", async () => {
    await open();
    (await waitFor(() => button("Change sign-in"), "the provider")).click();
    type(await waitFor(() => field("issuer"), "the form"), "https://other.example.com");
    button("Check these values")!.click();
    await waitFor(() => says("https://other.example.com did not answer for its discovery document."), "the failed check");

    button("Preview")!.click();
    (await waitFor(() => go("Save"), "the preview's Save")).click();
    await waitFor(() => says("the provider did not stand behind these values"), "the plane's refusal");
    expect(fake.admin.stored.has("issuer")).toBe(false);

    button("Back to editing")!.click();
    (await waitFor(() => field("Save anyway: the provider is down right now") as HTMLInputElement | null, "the choice to save anyway")).click();
    button("Preview")!.click();
    await waitFor(() => says("Saved without the provider standing behind it"), "the preview");
    (await waitFor(() => go("Save"), "the preview's Save")).click();
    await waitFor(() => says("Recorded in the audit as provider.put on sign-in"), "the audit's note");
    expect(fake.admin.stored.get("issuer")).toBe("https://other.example.com");

    (await waitFor(() => button("Back to the deployment"), "the reset")).click();
    await waitFor(() => says("Every sign-in value changed here goes"), "the reset's preview");
    (await waitFor(() => go("Put them back"), "the preview's Put them back")).click();
    await waitFor(() => says("Recorded in the audit as provider.reset on sign-in"), "the audit's note");
    expect(fake.admin.stored.has("issuer")).toBe(false);
  });

  it("sends a typed secret and never one that was not typed", async () => {
    await open();
    (await waitFor(() => button("Change sign-in"), "the provider")).click();
    type(await waitFor(() => field("client_secret"), "the form"), "a-new-secret");
    button("Preview")!.click();
    await waitFor(() => says("a new one, never shown"), "the preview");
    (await waitFor(() => go("Save"), "the preview's Save")).click();
    await waitFor(() => says("Recorded in the audit as provider.put on sign-in"), "the audit's note");
    expect(fake.admin.stored.get("client_secret")).toBe("a-new-secret");
    expect(JSON.stringify(fake.admin.audit)).not.toContain("a-new-secret");
    expect(says("a-new-secret")).toBe(false);
  });

  it("is read by a team admin, who is not shown sign-in in the map", async () => {
    await open(PEOPLE.bob);
    await waitFor(() => document.querySelector("h1")?.textContent === "Overview", "the overview instead");
  });
});

describe("the SCIM connector", () => {
  it("rotates its token, shown once, switches whether groups become teams, and forgets the token once the base URL is typed", async () => {
    await open();
    await waitFor(() => scim() && says("connected", scim()), "the connector");
    button("Rotate the token")!.click();
    await waitFor(() => says("The token set now stops working at once"), "the preview");
    (await waitFor(() => go("Rotate"), "the preview's Rotate")).click();
    await waitFor(() => says("The SCIM token, shown once"), "the new token");
    expect(document.querySelector(".shown-once pre")?.textContent ?? "").toMatch(/^scim_/);

    (await waitFor(() => button("Make teams from pushed groups"), "the switch")).click();
    await waitFor(() => says("becomes one, named from its display name"), "the preview");
    (await waitFor(() => go("Apply"), "the preview's Apply")).click();
    await waitFor(() => says("Recorded in the audit as scim.update on connector"), "the audit's note");
    expect(fake.admin.scimState.teams_from_groups).toBe(true);

    (await waitFor(() => button("Forget the token"), "the forget")).click();
    await waitFor(() => says("Type https://troupe.example.com/scim/v2 to confirm"), "the typed confirmation");
    expect(go("Forget it")).toBeUndefined();
    type(field("Type https://troupe.example.com/scim/v2 to confirm")!, "https://troupe.example.com/scim/v2");
        (await waitFor(() => go("Forget it"), "the preview's Forget it")).click();
    await waitFor(() => says("Recorded in the audit as scim.delete on connector") && says("off: no token", scim()), "the token forgotten");
  });
});
