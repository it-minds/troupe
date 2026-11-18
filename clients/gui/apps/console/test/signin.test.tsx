// Signing in to the console is the plane's own sign-in: the identity provider's page and
// back with a code (PKCE), the plane's `/auth/exchange`, and the plane token every client
// holds. What the person may administer is the plane's answer, on every call; the console
// asks `me` once for who they are and, on its administrative areas, calls nothing else but
// `admin.*`. Somebody who administers nothing signs in too, to Mine.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, recordCalls, render, says, sees, seesLink, signedInAs, startFake, type, visit, waitFor } from "./support";
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
    await sees("Alice");
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

  it("says the sign-in is to open an artifact when the address is one, and nothing more anywhere else", async () => {
    const line = (): string | null => document.querySelector("main.signin form p")?.textContent ?? null;

    visit("#/artifacts/open/art-carol-weekly/v2");
    unmount = render(<App />).unmount;
    await waitFor(() => button("Sign in"), "the sign-in screen");
    expect(line()).toBe("Sign in to open an artifact");
    unmount();

    visit("#/artifacts/link/token-followed-abcdefghijklmnop");
    unmount = render(<App />).unmount;
    await waitFor(() => button("Sign in"), "the sign-in screen");
    expect(line()).toBe("Sign in to open a shared artifact");
    unmount();

    // An artifact's page in the console, or any other screen, is the console's own sign-in.
    for (const hash of ["#/artifacts/art-carol-weekly", "#/teams/core/limits", ""]) {
      visit(hash);
      unmount = render(<App />).unmount;
      await waitFor(() => button("Sign in"), "the sign-in screen");
      expect(line()).toBeNull();
      unmount();
    }
    unmount = null;
  });

  it("goes straight to the provider for an artifact's address, drawing no page and asking nobody to choose an account", async () => {
    for (const hash of ["#/artifacts/open/art-carol-weekly/v2", "#/artifacts/link/token-followed-abcdefghijklmnop"]) {
      freshBrowser();
      localStorage.setItem("troupe.console.planeUrl", fake.plane.baseUrl);
      visit(hash);
      let leftFor: string | null = null;
      unmount = render(<App navigate={(url) => (leftFor = url)} />).unmount;
      const there = new URL(await waitFor(() => leftFor, `the way to the provider from ${hash}`));
      expect(there.origin).toBe(fake.idp.issuer);
      expect(there.searchParams.get("prompt")).toBeNull();
      expect(document.querySelector("main.signin form")).toBeNull();
      expect(button("Sign in")).toBeNull();
      // The place goes with the person to the provider and back.
      expect(sessionStorage.getItem("troupe.console.returnTo")).toBe(hash);
      unmount();
    }
    unmount = null;
  });

  it("draws its page, not the provider's, for the console's own addresses", async () => {
    localStorage.setItem("troupe.console.planeUrl", fake.plane.baseUrl);
    for (const hash of ["", "#/teams/core/limits", "#/artifacts/art-carol-weekly"]) {
      visit(hash);
      let leftFor: string | null = null;
      unmount = render(<App navigate={(url) => (leftFor = url)} />).unmount;
      await waitFor(() => button("Sign in"), `the sign-in screen at "${hash}"`);
      expect(leftFor).toBeNull();
      unmount();
    }
    unmount = null;
  });

  it("draws its page when the plane names no provider to go to, with break-glass the only way in", async () => {
    // A plane deployed without a provider answers its discovery with no issuer.
    const original = globalThis.fetch;
    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const answer = await original(input, init);
      if (!String(input instanceof Request ? input.url : input).endsWith("/.well-known/troupe")) return answer;
      const found = (await answer.json()) as Record<string, unknown>;
      return new Response(JSON.stringify({ ...found, issuer: null, breakglass: true }), { status: 200, headers: { "content-type": "application/json" } });
    };
    restore = () => void (globalThis.fetch = original);
    localStorage.setItem("troupe.console.planeUrl", fake.plane.baseUrl);
    visit("#/artifacts/open/art-carol-weekly");
    let leftFor: string | null = null;
    unmount = render(<App navigate={(url) => (leftFor = url)} />).unmount;
    await waitFor(() => button("Sign in"), "the sign-in screen");
    expect(document.querySelector("main.signin form p")?.textContent).toBe("Sign in to open an artifact");
    await waitFor(() => button("Break glass"), "the break-glass door");
    expect(leftFor).toBeNull();
  });

  it("goes to the provider once by itself: a refusal comes back to its page, saying so, and it does not go again", async () => {
    localStorage.setItem("troupe.console.planeUrl", fake.plane.baseUrl);
    visit("#/artifacts/open/art-carol-weekly");
    const left: string[] = [];
    unmount = render(<App navigate={(url) => void left.push(url)} />).unmount;
    const there = new URL(await waitFor(() => left[0], "the way to the provider"));
    unmount();

    // The provider refuses and sends the browser back to the console's bare address.
    const state = there.searchParams.get("state")!;
    history.replaceState(null, "", `/?error=access_denied&error_description=${encodeURIComponent("not for you")}&state=${state}`);
    unmount = render(<App navigate={(url) => void left.push(url)} />).unmount;
    await waitFor(() => button("Sign in"), "the sign-in screen, after the refusal");
    await sees("access_denied: not for you");
    expect(document.querySelector("main.signin form p")?.textContent).toBe("Sign in to open an artifact");
    expect(location.hash).toBe("#/artifacts/open/art-carol-weekly");
    await new Promise((r) => setTimeout(r, 400));
    expect(left).toHaveLength(1);

    // The button still goes, when the person presses it.
    button("Sign in")!.click();
    await waitFor(() => left[1], "the way to the provider, asked for");
  });

  it("draws its page for somebody who comes back from the provider's own page with Back, rather than sending them there again", async () => {
    localStorage.setItem("troupe.console.planeUrl", fake.plane.baseUrl);
    visit("#/artifacts/link/token-followed-abcdefghijklmnop");
    const left: string[] = [];
    unmount = render(<App navigate={(url) => void left.push(url)} />).unmount;
    await waitFor(() => left[0], "the way to the provider");
    unmount();

    // Back from the provider's page: the same address, and no answer from it.
    unmount = render(<App navigate={(url) => void left.push(url)} />).unmount;
    await waitFor(() => button("Sign in"), "the sign-in screen");
    expect(document.querySelector("main.signin form p")?.textContent).toBe("Sign in to open a shared artifact");
    await new Promise((r) => setTimeout(r, 400));
    expect(left).toHaveLength(1);
  });

  it("does not go to the provider by itself after the person signs out, wherever the address is", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/artifacts/open/art-nobody-has");
    const left: string[] = [];
    unmount = render(<App navigate={(url) => void left.push(url)} />).unmount;
    await sees("This artifact cannot be opened");
    button("Sign out")!.click();
    await waitFor(() => button("Sign in"), "the sign-in screen");
    await new Promise((r) => setTimeout(r, 400));
    expect(left).toEqual([]);
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
    expect(link("Provisioners and hosts")).toBeNull();
    expect(link("Pods")).toBeNull();
    expect(link("Sign-in")).toBeNull();
    expect(link("Connections")).toBeNull();
    await seesLink("Triggers");
    // What the plane answers a team admin: the integrations to read, and their team's principals.
    await seesLink("Integrations");
    await seesLink("Identity");
    await seesLink("Teams");
    await seesLink("Client versions");
  });

  it("signs in somebody who administers nothing to what is theirs, with no administrative area and none by its address", async () => {
    await signedInAs(fake, PEOPLE.carol);
    visit("#/teams");
    unmount = render(<App />).unmount;
    await waitFor(() => says("member") && document.querySelector("h1")?.textContent === "Mine", "Mine, as a member");
    await sees("Carol");
    await seesLink("Mine");
    for (const area of ["Overview", "Sessions", "Teams", "Identity", "Audit", "Client versions", "Company memory"]) expect(link(area), area).toBeNull();
  });

  it("gives an administrator Mine as well, above the administrative map", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => says("team admin · design"), "the console, as the design team's admin");
    (await seesLink("Mine")).click();
    await waitFor(() => document.querySelector("h1")?.textContent === "Mine", "Mine");
    await seesLink("Teams");
  });

  it("says plainly when the plane does not answer, as an alert that asks again from where it stands", async () => {
    unmount = render(<App navigate={() => undefined} />).unmount;
    type(await waitFor(() => field("The plane's address"), "the sign-in screen"), "http://127.0.0.1:1");
    button("Sign in")!.click();
    const alert = await waitFor(() => document.querySelector<HTMLElement>(".banner.error[role=alert]"), "the error, as an alert");
    await sees("The plane at http://127.0.0.1:1 did not answer. Check the address and try again.");
    const retry = await waitFor(() => button("Try again", alert), "the retry");
    // Asking again clears the alert and asks the same address, which says the same again.
    retry.click();
    await waitFor(() => {
      const again = document.querySelector<HTMLElement>(".banner.error[role=alert]");
      return again && again !== alert && button("Try again", again);
    }, "a new alert from the second try, with its retry");
  });
});
