// What the console's tests need that a browser would have: a page to render into, a way
// to click and type, a fake plane with its administrative half, and a record of every
// call the page makes to it.
//
// No testing library, as in the desktop app's tests: find the control by what it says,
// press it, and wait until the screen says something. The desktop app's helpers are not
// imported; the two apps share no code but the protocol client.

import { createRoot } from "react-dom/client";
import type { ReactElement } from "react";
import { AuthSession } from "@troupe/client";
import { FakeAdmin, exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { FakeIdp } from "../../../packages/client/test/support/idp.js";
import { FakePlane } from "../../../packages/client/test/support/plane.js";
import { FakeWorker } from "../../../packages/client/test/support/worker.js";
import { tabTokenStore } from "../src/plane";

export const PEOPLE = {
  alice: { subject: "alice@example.com", name: "Alice" },
  bob: { subject: "bob@example.com", name: "Bob" },
  carol: { subject: "carol@example.com", name: "Carol" },
} as const;

export interface FakeDeployment {
  idp: FakeIdp;
  worker: FakeWorker;
  plane: FakePlane;
  admin: FakeAdmin;
  stop(): Promise<void>;
}

/** An identity provider, a worker and a plane with the example organisation behind it. */
export async function startFake(admin: FakeAdmin = exampleAdmin()): Promise<FakeDeployment> {
  const idp = await FakeIdp.start();
  const worker = await FakeWorker.start();
  const plane = await FakePlane.start({ idp, worker, admin });
  return {
    idp,
    worker,
    plane,
    admin,
    async stop() {
      await plane.stop();
      await worker.stop();
      await idp.stop();
    },
  };
}

/**
 * Leave this tab signed in as `who`, the way a sign-in the provider sent back leaves it: a
 * refresh token in the tab's store, and the plane's address remembered. The console's own
 * load then signs back in from it, with no screen in between.
 */
export async function signedInAs(fake: FakeDeployment, who: { subject: string; name: string }): Promise<void> {
  const auth = new AuthSession({ planeUrl: fake.plane.baseUrl, store: tabTokenStore(), flow: "device" });
  let approving: ReturnType<typeof setTimeout> | undefined;
  try {
    await auth.signIn({ onDeviceCode: () => void (approving = setTimeout(() => fake.idp.approve(who.subject, who.name), 20)) });
  } finally {
    if (approving) clearTimeout(approving);
  }
  localStorage.setItem("troupe.console.planeUrl", fake.plane.baseUrl);
}

export interface Call {
  url: string;
  method: string | null;
}

/** Every request the page makes, with the JSON-RPC method of each that is one. */
export function recordCalls(): { calls: Call[]; restore: () => void } {
  const calls: Call[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input);
    let method: string | null = null;
    if (typeof init?.body === "string") {
      try {
        const m = (JSON.parse(init.body) as { method?: unknown }).method;
        method = typeof m === "string" ? m : null;
      } catch {
        // A form body, to the provider.
      }
    }
    calls.push({ url, method });
    return original(input, init);
  };
  return { calls, restore: () => void (globalThis.fetch = original) };
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

/**
 * Poll until `find` answers something, the way a person waits for a screen. A `find` that
 * throws has not found it yet: a row it reaches into can be gone for a render while the
 * screen redraws it. At the deadline the last thing it threw is said.
 */
export async function waitFor<T>(find: () => T | null | undefined | false, what: string, timeoutMs = 10_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    let found: T | null | undefined | false = null;
    let threw: unknown = null;
    try {
      found = find();
    } catch (e) {
      threw = e;
    }
    if (found) return found;
    if (Date.now() > deadline) {
      const why = threw ? ` (it last threw: ${threw instanceof Error ? threw.message : String(threw)})` : "";
      throw new Error(`timed out waiting for ${what}${why}. The page says:\n${document.body.textContent ?? ""}`);
    }
    await sleep(20);
  }
}

/** Whether the page says this anywhere. */
export function says(text: string, within: ParentNode = document.body): boolean {
  return (within.textContent ?? "").includes(text);
}

/**
 * Wait until the page says this. The assertion for anything that shows after an async
 * step: a line drawn by another render than the one a `waitFor` saw is not there yet in
 * the same tick, on a busy machine. `expect(says(…)).toBe(true)` is refused by
 * `waits.test.ts` unless its line says why it is meant at once (`// at once: <why>`).
 */
export async function sees(text: string, within: ParentNode | (() => ParentNode | null | undefined) = document.body): Promise<void> {
  // A function is asked again on every look: the row it finds can be drawn anew meanwhile.
  await waitFor(() => {
    const at = typeof within === "function" ? within() : within;
    return Boolean(at) && says(text, at!);
  }, `the page to say "${text}"`);
}

/** Wait for the link whose words begin with `label`, as `sees` waits for words. */
export function seesLink(label: string, within: ParentNode = document): Promise<HTMLAnchorElement> {
  return waitFor(() => link(label, within), `the link "${label}"`);
}

/** The button whose words begin with `label`. */
export function button(label: string, within: ParentNode = document): HTMLButtonElement | null {
  return [...within.querySelectorAll("button")].find((b) => (b.textContent ?? "").trim().startsWith(label)) ?? null;
}

/**
 * Wait for the button whose words begin with `label`, as `sees` waits for words, and answer
 * it. `expect(button(…)).not.toBeNull()` and a read of a button found at once
 * (`button(…)!.disabled`) are refused by `waits.test.tsx` unless marked `// at once: <why>`.
 */
export function seesButton(label: string, within: ParentNode = document): Promise<HTMLButtonElement> {
  return waitFor(() => button(label, within), `the button "${label}"`);
}

/** Wait for the field a label names, as `seesButton` waits for a button, and answer it. */
export function seesField(label: string, within: ParentNode = document): Promise<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement> {
  return waitFor(() => field(label, within), `the field "${label}"`);
}

/** The link whose words begin with `label`. */
export function link(label: string, within: ParentNode = document): HTMLAnchorElement | null {
  return [...within.querySelectorAll("a")].find((a) => (a.textContent ?? "").trim().startsWith(label)) ?? null;
}

/** The field a label names, by the label's words: the control it is for, or the one inside it. */
export function field(label: string, within: ParentNode = document): HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement | null {
  const found = [...within.querySelectorAll("label")].find((l) => (l.textContent ?? "").trim().startsWith(label));
  if (!found) return null;
  const control = found.htmlFor ? document.getElementById(found.htmlFor) : null;
  if (control instanceof HTMLInputElement || control instanceof HTMLSelectElement || control instanceof HTMLTextAreaElement) return control;
  return found.querySelector<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>("input, select, textarea");
}

/** Type into a field, or choose in a select, the way React hears it. */
export function type(el: HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement, value: string): void {
  const proto = el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(el, value);
  el.dispatchEvent(new Event(el instanceof HTMLSelectElement ? "change" : "input", { bubbles: true }));
}

/** Go to a place in the console, as a link or a typed address would. */
export function visit(hash: string): void {
  location.hash = hash;
}

/** Clear what one test leaves in the browser for the next. */
export function freshBrowser(): void {
  localStorage.clear();
  sessionStorage.clear();
  history.replaceState(null, "", "/");
  document.documentElement.removeAttribute("data-mode");
}
