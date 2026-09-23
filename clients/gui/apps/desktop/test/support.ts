// What the app's tests need that a browser would have: a page to render into, a way to
// click and type, and a record of every request the page makes.
//
// No testing library. The app is driven the way a person drives it — find the button
// by what it says, press it, wait until the screen says something — and that is a page
// of code rather than a dependency.

import { createRoot } from "react-dom/client";
import type { ReactElement } from "react";

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

export function render(element: ReactElement): { unmount: () => void } {
  const container = document.createElement("div");
  document.body.appendChild(container);
  const root = createRoot(container);
  root.render(element);
  return {
    unmount: () => {
      root.unmount();
      container.remove();
    },
  };
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Poll until `find` answers something, the way a person waits for a screen. */
export async function waitFor<T>(find: () => T | null | undefined | false, what: string, timeoutMs = 10_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const found = find();
    if (found) return found;
    if (Date.now() > deadline) {
      throw new Error(`timed out waiting for ${what}. The page says:\n${document.body.textContent ?? ""}`);
    }
    await sleep(20);
  }
}

/** Whether the page says this anywhere. */
export function says(text: string): boolean {
  return (document.body.textContent ?? "").includes(text);
}

/** The button whose words begin with `label`, inside `within` if given. */
export function button(label: string, within: ParentNode = document): HTMLButtonElement | null {
  return [...within.querySelectorAll("button")].find((b) => (b.textContent ?? "").trim().startsWith(label)) ?? null;
}

/** A navigation entry in the rail, which carries counts after its name. */
export function nav(label: string): HTMLButtonElement | null {
  return button(label, document.querySelector(".rail nav") ?? document);
}

/** Type into a field the way React hears it: through the native setter, then an input event. */
export function type(field: HTMLInputElement | HTMLTextAreaElement, value: string): void {
  const proto = field instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(field, value);
  field.dispatchEvent(new Event("input", { bubbles: true }));
}
