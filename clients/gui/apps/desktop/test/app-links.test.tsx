// The app's own `troupe://` links (troupe #959), as the shell hands them over:
//
//   - a link to a plane the app is not signed in to opens the sign-in screen with the
//     address filled in and the sentence asking, and nothing is sent to that plane until
//     the person presses Sign in; signed in, the app goes on to the place;
//   - a link that is not one of the three forms is said in a line and nothing else happens;
//   - a link to another plane than the one signed in to asks before signing out;
//   - "Copy link" on a session copies its troupe:// link, and the console's page under it
//     where the session has one there.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { sessionLinkText, signInSentence, stepFor } from "../src/links";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, recordNetwork, render, says, sees, sleep, waitFor } from "./support";
import type { Recorder } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness;
let unmount: (() => void) | null = null;
let network: Recorder | null = null;
let deliver: ((links: string[]) => void) | null = null;

const address = (): HTMLInputElement | null => document.querySelector<HTMLInputElement>(".signin input");
const host = (): string => new URL(harness.plane.baseUrl).host;

beforeEach(async () => {
  localStorage.clear();
  sessionStorage.clear();
  harness = await startHarness();
  deliver = null;
  window.troupe = {
    name: "Test shell",
    version: "0",
    signInFlow: "device",
    onLinks: (listener) => {
      deliver = listener;
      return () => {
        deliver = null;
      };
    },
  };
});

afterEach(async () => {
  network?.restore();
  network = null;
  unmount?.();
  unmount = null;
  delete window.troupe;
  await harness.stop();
});

async function link(text: string): Promise<void> {
  const send = await waitFor(() => deliver, "the app listening for links");
  send([text]);
}

describe("a link to a plane the app is not signed in to", () => {
  it("asks on the sign-in screen with the address filled in, sends nothing until Sign in, then goes there", async () => {
    unmount = render(<App />).unmount;
    await waitFor(address, "the sign-in screen");
    network = recordNetwork();
    await link(`troupe://open?plane=${encodeURIComponent(harness.plane.baseUrl)}`);

    await sees(`This link is for ${host()}. Sign in there?`);
    expect(address()!.value).toBe(harness.plane.baseUrl);
    await sleep(300);
    expect(network.requests.filter((r) => r.url.startsWith(harness.plane.baseUrl))).toEqual([]);
    expect(document.querySelector(".usercode")).toBeNull();

    button("Sign in")!.click();
    await waitFor(() => document.querySelector(".usercode"), "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada."), "signed in");
  });
});

describe("a link the app does not follow", () => {
  it("is said in a line on the sign-in screen, and nothing else happens", async () => {
    localStorage.setItem("troupe.pref.planeUrl", "https://kept.example");
    unmount = render(<App />).unmount;
    await waitFor(address, "the sign-in screen");
    await link(`troupe://session/s-1?plane=${encodeURIComponent("https://troupe.example.com")}&token=secret`);
    await sees("This link was not followed: it carries more than a place and a plane, and Troupe takes nothing else from a link.");
    expect(address()!.value).toBe("https://kept.example");
  });
});

describe("what a link leads to", () => {
  const plane = "https://troupe.example.com";

  it("signed in there, straight to the place; signed in elsewhere, a question; nowhere, the sign-in", () => {
    expect(stepFor(`troupe://session/s-1?plane=${encodeURIComponent(plane)}`, { signedIn: `${plane}/`, localOnly: false })).toEqual({ do: "go", to: { screen: "session", id: "s-1" } });
    expect(stepFor(`troupe://artifact/a-1?plane=${encodeURIComponent(plane)}`, { signedIn: plane, localOnly: false })).toEqual({ do: "go", to: { screen: "artifacts", artifact: "a-1" } });
    expect(stepFor(`troupe://open?plane=${encodeURIComponent(plane)}`, { signedIn: plane, localOnly: false })).toEqual({ do: "front" });
    expect(stepFor("troupe://open", { signedIn: null, localOnly: true })).toEqual({ do: "front" });
    expect(stepFor(`troupe://session/s-1?plane=${encodeURIComponent(plane)}`, { signedIn: null, localOnly: false })).toEqual({
      do: "sign-in",
      plane,
      sentence: signInSentence(plane),
      then: { screen: "session", id: "s-1" },
    });
    expect(stepFor(`troupe://session/s-1?plane=${encodeURIComponent(plane)}`, { signedIn: "https://other.example", localOnly: false })).toMatchObject({
      do: "switch",
      sentence: "This link is for troupe.example.com, and this app is signed in to other.example.",
    });
    expect(stepFor(`troupe://open?plane=${encodeURIComponent(plane)}`, { signedIn: null, localOnly: true })).toEqual({
      do: "say",
      sentence: "This link is for troupe.example.com, and this app uses this computer only. Turn Local only off on This computer to follow it.",
    });
  });

  it("Copy link on a session copies its app link, and the console's page for a private one", () => {
    expect(sessionLinkText("s-1", plane, "https://troupe.example.com/console/", true)).toBe(
      "troupe://session/s-1?plane=https%3A%2F%2Ftroupe.example.com\nhttps://troupe.example.com/console/#/mine/invited/s-1",
    );
    expect(sessionLinkText("s-1", plane, "https://troupe.example.com/console", false)).toBe("troupe://session/s-1?plane=https%3A%2F%2Ftroupe.example.com");
    expect(sessionLinkText("s-1", plane, null, true)).toBe("troupe://session/s-1?plane=https%3A%2F%2Ftroupe.example.com");
  });
});
