
// What the app's tests need that a browser would have and the console's do not: a record
// of every request the page makes, and the app's own ways about its screens. The page
// helpers both apps' tests drive their page with (render, wait, find a button, type) are
// `@troupe/test-support`'s, re-exported here.

import { createElement } from "react";
import { button, enabled, render, seesButton, type, waitFor } from "@troupe/test-support";
import { App } from "../src/App";
import type { FakeDaemon } from "../../../packages/client/test/support/daemon.js";

export * from "@troupe/test-support";

export interface Sent {
  via: "fetch" | "websocket" | "xhr" | "beacon" | "eventsource";
  url: string;
}

export interface Recorder {
  readonly requests: Sent[];
  clear(): void;
  restore(): void;
}

/**
 * Record every way a page can reach the network, before the app is rendered.
 *
 * `refuse` makes a `fetch` fail the way a plane that is down fails in a browser — a
 * bare `TypeError`, before any response — and it is still recorded, because an attempt
 * is a request whether or not it arrived.
 */
export function recordNetwork(opts: { refuse?: (url: string) => boolean } = {}): Recorder {
  const requests: Sent[] = [];
  const g = globalThis as unknown as Record<string, unknown>;
  const undo: Array<() => void> = [];

  const swap = (key: string, value: unknown): void => {
    const before = g[key];
    g[key] = value;
    undo.push(() => {
      g[key] = before;
    });
  };

  const fetch = globalThis.fetch;
  swap("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input);
    requests.push({ via: "fetch", url });
    if (opts.refuse?.(url)) return Promise.reject(new TypeError("fetch failed"));
    return fetch(input, init);
  });

  // A proxy rather than a subclass, so whichever WebSocket the environment has — jsdom's
  // or Node's — keeps its own constructor checks and static constants.
  const socketLike = (key: "WebSocket" | "EventSource", via: Sent["via"]): void => {
    const Original = g[key] as (new (...args: unknown[]) => object) | undefined;
    if (!Original) return;
    swap(
      key,
      new Proxy(Original, {
        construct(target, args: unknown[]) {
          requests.push({ via, url: String(args[0]) });
          return Reflect.construct(target, args) as object;
        },
      }),
    );
  };
  socketLike("WebSocket", "websocket");
  socketLike("EventSource", "eventsource");

  const XHR = g["XMLHttpRequest"] as { prototype: { open: (...args: unknown[]) => void } } | undefined;
  if (XHR) {
    const open = XHR.prototype.open;
    XHR.prototype.open = function (this: unknown, ...args: unknown[]) {
      requests.push({ via: "xhr", url: String(args[1]) });
      return open.apply(this, args);
    };
    undo.push(() => {
      XHR.prototype.open = open;
    });
  }

  const nav = g["navigator"] as { sendBeacon?: (url: string, data?: unknown) => boolean } | undefined;
  if (nav && typeof nav.sendBeacon === "function") {
    const beacon = nav.sendBeacon.bind(nav);
    nav.sendBeacon = (url, data) => {
      requests.push({ via: "beacon", url: String(url) });
      return beacon(url, data);
    };
    undo.push(() => {
      nav.sendBeacon = beacon;
    });
  }

  return {
    requests,
    clear: () => void requests.splice(0),
    restore: () => {
      for (const u of undo.reverse()) u();
    },
  };
}

/**
 * Anything the rendered page would load by itself: an image, a frame, a script or a
 * stylesheet at an address. jsdom does not fetch these, so a recorder would never see
 * one; the markup is where they would show.
 */
export function externalResources(): string[] {
  const loaders = "img[src], iframe[src], script[src], link[href], source[src], video[src], audio[src], object[data], embed[src]";
  return [...document.querySelectorAll(loaders)]
    .map((el) => el.getAttribute("src") ?? el.getAttribute("href") ?? el.getAttribute("data") ?? "")
    .filter((url) => /^(https?:)?\/\//i.test(url));
}

/**
 * The session's backstage, shown as a person shows it (it starts hidden): Show backstage
 * under the head's ⋯, once the session is drawn.
 */
export async function showBackstage(): Promise<HTMLElement> {
  const shown = document.querySelector<HTMLElement>(".backstage");
  if (shown) return shown;
  (await seesButton("Show backstage")).click();
  return waitFor(() => document.querySelector<HTMLElement>(".backstage"), "the backstage");
}

/**
 * Start where a person who chose the list starts, rather than on the launcher (Decision
 * 709). For the suites about the list and what opens from it; `launcher.test.tsx` is the
 * one about the first screen. Call it after `localStorage.clear()`.
 */
export function startOnTheList(): void {
  localStorage.setItem("troupe.pref.start", "sessions");
}

/** A navigation entry in the rail, which carries counts after its name. */
export function nav(label: string): HTMLButtonElement | null {
  return button(label, document.querySelector(".rail nav") ?? document);
}

/**
 * On the new-session screen, put the session on this computer, in `workspace`, as a person
 * does: the sentence's where chip, "On this computer" once it is on, the folder typed.
 */
export async function hereIn(start: HTMLElement, workspace: string): Promise<void> {
  const chip = await waitFor(() => start.querySelector<HTMLButtonElement>('button.ns-chip[aria-label^="Where it runs"]'), "the where chip");
  if (!chip.textContent?.includes("on this computer")) {
    chip.click();
    (await waitFor(() => enabled(button("On this computer", start)), "On this computer, on")).click();
  }
  type(await waitFor(() => start.querySelector<HTMLInputElement>('input[aria-label="Which directory"]'), "the folder"), workspace);
}

/** The new-session screen's start button, once it may be pressed. */
export function startButton(start: HTMLElement): Promise<HTMLButtonElement> {
  return waitFor(() => enabled(start.querySelector<HTMLButtonElement>("button.ns-start")), "the start button, on");
}

/**
 * Open a session on this computer as a person does: the app drawn, the session's row in
 * the list pressed, and the screen attached (it has read the session's loop). `open`
 * answers the composer; `close` takes the page down again, for the suite's `afterEach`.
 */
export function sessionOpener(daemon: () => FakeDaemon): { open(workspace: string): Promise<HTMLTextAreaElement>; close(): void } {
  let unmount: (() => void) | null = null;
  return {
    async open(workspace) {
      unmount = render(createElement(App)).unmount;
      const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace)), "the session in the list");
      row.click();
      const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
      await waitFor(() => daemon().calls.some((c) => c.method === "session.loop.get"), "the screen attached");
      return composer;
    },
    close() {
      unmount?.();
      unmount = null;
    },
  };
}
