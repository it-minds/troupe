// The break-glass door on the sign-in screen: there only on a plane whose discovery says it
// has one, it takes the plane's break-glass token for a session that leans on the identity
// provider for nothing and signs in a platform administrator with no teams. Every page says
// so, and when the session's token expires the console is back at its sign-in, saying why.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { button, field, freshBrowser, link, recordCalls, render, sees, seesButton, seesField, seesLink, sleep, startFake, type, waitFor } from "./support";
import type { FakeDeployment } from "./support";

const GLASS = "glass-7a1f";

let fake: FakeDeployment | null = null;
let unmount: (() => void) | null = null;
let restore: (() => void) | null = null;

beforeEach(() => {
  freshBrowser();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  restore?.();
  restore = null;
  await fake?.stop();
  fake = null;
});

/** The sign-in screen, with the plane's address typed in. */
async function atSignIn(plane: FakeDeployment): Promise<void> {
  unmount = render(<App navigate={() => undefined} />).unmount;
  type(await waitFor(() => field("The plane's address"), "the sign-in screen"), plane.plane.baseUrl);
}

describe("the break-glass door", () => {
  it("is not on the sign-in screen of a plane that has none", async () => {
    fake = await startFake();
    const recorded = recordCalls();
    restore = recorded.restore;
    await atSignIn(fake);
    // The screen asked the plane and heard there is no door: nothing more will appear.
    await waitFor(() => recorded.calls.some((c) => c.url.endsWith("/.well-known/troupe")), "the discovery");
    await sleep(100);
    await seesButton("Sign in");
    expect(button("Break glass")).toBeNull();
    expect(field("Break-glass token")).toBeNull();
  });

  it("opens the console as a platform admin with no teams, with a banner on every page saying why", async () => {
    fake = await startFake(exampleAdmin(), { breakglass: GLASS });
    const recorded = recordCalls();
    restore = recorded.restore;
    await atSignIn(fake);
    await sees("For the day the identity provider cannot sign anybody in.");
    const token = await seesField("Break-glass token");
    expect(token.getAttribute("type")).toBe("password");

    type(token, "not-the-token");
    (await seesButton("Break glass")).click();
    await sees("The plane refused this break-glass token.");

    type(await seesField("Break-glass token"), GLASS);
    (await seesButton("Break glass")).click();
    await sees("platform admin");
    await sees("Break-glass session.");
    await sees("because you presented the plane's break-glass token");
    await sees("This session ends at");
    await sees("Break-glass administrator");
    await seesLink("Overview");
    await seesLink("Teams");

    // The banner is on every page, not the first alone.
    (await seesLink("Sessions")).click();
    await waitFor(() => document.querySelector("h1")?.textContent === "Sessions", "Sessions");
    await sees("Break-glass session.");

    // The plane was never asked to exchange an id token, and the provider was never visited.
    expect(recorded.calls.some((c) => c.url.endsWith("/auth/breakglass"))).toBe(true);
    expect(recorded.calls.some((c) => c.url.endsWith("/auth/exchange"))).toBe(false);
    expect(recorded.calls.some((c) => c.url.startsWith(fake!.idp.issuer))).toBe(false);
    // Nothing kept for a reload: the tab's store holds no refresh token.
    expect(Object.keys(sessionStorage).some((k) => k.startsWith("troupe.console.auth."))).toBe(false);
  });

  it("returns to the sign-in screen when the session's token expires, saying so", async () => {
    fake = await startFake(exampleAdmin(), { breakglass: GLASS, breakglassLifetime: 2 });
    await atSignIn(fake);
    type(await seesField("Break-glass token"), GLASS);
    (await seesButton("Break glass")).click();
    await sees("Break-glass session.");

    await sees("The break-glass session ended at");
    await sees("nothing renews it. Sign in again.");
    await seesButton("Sign in");
    expect(link("Overview")).toBeNull();
  });
});
