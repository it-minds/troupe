// Signing in to the console is the plane's own sign-in: the identity provider's page and
// back with a code (PKCE), the plane's `/auth/exchange`, and the plane token every client
// holds. What the person may administer is the plane's answer, on every call; the console
// asks `me` once for who they are and calls nothing else but `admin.*`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, recordCalls, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;
let restore: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  restore?.();
  restore = null;
  await fake.stop();
});

describe("signing in to the console", () => {
  it("goes to the provider and back, exchanges at the plane, and calls only me and admin methods after", async () => {
    const recorded = recordCalls();
    restore = recorded.restore;
    let leftFor: string | null = null;
    unmount = render(<App navigate={(url) => (leftFor = url)} />).unmount;

    type(await waitFor(() => field("The plane's address"), "the sign-in screen"), fake.plane.baseUrl);
    button("Sign in")!.click();
    const there = await waitFor(() => leftFor, "the way to the provider");

    // The provider's page: PKCE, back to the console's own address.
    const asked = new URL(there);
    expect(asked.origin).toBe(fake.idp.issuer);
    expect(asked.searchParams.get("code_challenge_method")).toBe("S256");
    expect(asked.searchParams.get("redirect_uri")).toBe(location.origin);

    // Alice approves there, and the provider sends the browser back with a code.
    const back = await fetch(there, { redirect: "manual" });
    const returned = new URL(back.headers.get("location")!);
    unmount();
    history.replaceState(null, "", `/${returned.search}`);
    unmount = render(<App />).unmount;

    await waitFor(() => says("platform admin"), "the console, signed in");
    expect(says("Alice")).toBe(true);
    expect(location.search).toBe("");
    await waitFor(() => says("core") && says("design"), "the overview's teams");

    const toPlane = recorded.calls.filter((c) => c.url.startsWith(fake.plane.baseUrl));
    expect(toPlane.some((c) => c.url.endsWith("/auth/exchange"))).toBe(true);
    const methods = toPlane.map((c) => c.method).filter((m): m is string => m !== null);
    expect(methods).toContain("admin.overview");
    expect(methods.filter((m) => m !== "me" && !m.startsWith("admin."))).toEqual([]);
  });

  it("lands on the page a deep link asked for once the provider sends the browser back, not on the first screen", async () => {
    visit("#/teams/core/limits");
    let leftFor: string | null = null;
    unmount = render(<App navigate={(url) => (leftFor = url)} />).unmount;
    type(await waitFor(() => field("The plane's address"), "the sign-in screen"), fake.plane.baseUrl);
    button("Sign in")!.click();
    const there = await waitFor(() => leftFor, "the way to the provider");

    // The provider sends the browser back to the console's own address, which carries no
    // fragment: the redirect URI is registered without one.
    const back = await fetch(there, { redirect: "manual" });
    const returned = new URL(back.headers.get("location")!);
    expect(returned.hash).toBe("");
    unmount();
    history.replaceState(null, "", `/${returned.search}`);
    unmount = render(<App />).unmount;

    await waitFor(() => document.querySelector("h1")?.textContent === "core" && says("Every limit says what is in force"), "core's limits");
    expect(location.hash).toBe("#/teams/core/limits");
    expect(location.search).toBe("");
  });

  it("keeps the sign-in for this tab, and signing out forgets it", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("platform admin"), "the console, signed back in");
    expect(Object.keys(sessionStorage).some((k) => k.startsWith("troupe.console.auth."))).toBe(true);
    expect(Object.keys(localStorage).some((k) => k.includes("refresh"))).toBe(false);

    button("Sign out")!.click();
    await waitFor(() => button("Sign in"), "the sign-in screen");
    expect(Object.keys(sessionStorage).some((k) => k.startsWith("troupe.console.auth."))).toBe(false);
  });

  it("shows a team admin their own teams, and none of the areas only a platform admin uses", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => says("team admin · design"), "the console, as the design team's admin");
    await waitFor(() => link("design"), "the design team");
    expect(link("core")).toBeNull();
    expect(link("Integrations")).toBeNull();
    expect(link("Triggers")).not.toBeNull();
    expect(link("Identity")).toBeNull();
    expect(link("Teams")).not.toBeNull();
    expect(link("Client versions")).not.toBeNull();
  });

  it("tells somebody who administers nothing so, rather than showing them a console of refusals", async () => {
    await signedInAs(fake, PEOPLE.carol);
    unmount = render(<App />).unmount;
    await waitFor(() => says("Nothing to administer here"), "the refusal");
    expect(says("Carol")).toBe(true);
    expect(link("Teams")).toBeNull();
  });

  it("says plainly when the plane does not answer", async () => {
    unmount = render(<App navigate={() => undefined} />).unmount;
    type(await waitFor(() => field("The plane's address"), "the sign-in screen"), "http://127.0.0.1:1");
    button("Sign in")!.click();
    await waitFor(() => document.querySelector(".banner.error"), "the error");
    expect(says("could not reach the plane")).toBe(true);
  });
});
