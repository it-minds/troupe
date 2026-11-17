// What the console's tests need that the desktop app's do not: a fake plane with its
// administrative half, a record of every call the page makes to it, and the console's own
// ways about its screens. The page helpers both apps' tests drive their page with (render,
// wait, find a button, type) are `@troupe/test-support`'s, re-exported here; the apps
// themselves share no code but the protocol client.

import { createElement } from "react";
import { AuthSession } from "@troupe/client";
import { render, waitFor } from "@troupe/test-support";
import { App } from "../src/App";
import { FakeAdmin, exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { FakeIdp } from "../../../packages/client/test/support/idp.js";
import { FakePlane } from "../../../packages/client/test/support/plane.js";
import type { PlaneOptions } from "../../../packages/client/test/support/plane.js";
import { FakeWorker } from "../../../packages/client/test/support/worker.js";
import { NodeWebSocket } from "../../../packages/client/test/support/ws.js";
import { tabTokenStore } from "../src/plane";

// Mine holds a watch on the plane (`/v1/relay/watch`) wherever it is drawn, and the test
// environment's own WebSocket cannot open one against the fake: Node's can.
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

export * from "@troupe/test-support";

type AppProps = NonNullable<Parameters<typeof App>[0]>;
type Person = { subject: string; name: string };

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
export async function startFake(admin: FakeAdmin = exampleAdmin(), plane_: Partial<PlaneOptions> = {}): Promise<FakeDeployment> {
  const idp = await FakeIdp.start();
  const worker = await FakeWorker.start();
  const plane = await FakePlane.start({ ...plane_, idp, worker, admin });
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

/** Wait for the link whose words begin with `label`, as `sees` waits for words. */
export function seesLink(label: string, within: ParentNode = document): Promise<HTMLAnchorElement> {
  return waitFor(() => link(label, within), `the link "${label}"`);
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

/** Go to a place in the console, as a link or a typed address would. */
export function visit(hash: string): void {
  location.hash = hash;
}

/**
 * Open the console as a person does: signed in to the suite's deployment as `who` (Alice
 * unless said), at `hash`, the app drawn with `props`. `close` takes the page down again,
 * for the suite's `afterEach`.
 */
export function opener(deployment: () => FakeDeployment, props: AppProps = {}): { open(hash: string, who?: Person): Promise<void>; close(): void } {
  let unmount: (() => void) | null = null;
  return {
    async open(hash, who = PEOPLE.alice) {
      await signedInAs(deployment(), who);
      visit(hash);
      unmount = render(createElement<AppProps>(App, props)).unmount;
    },
    close() {
      unmount?.();
      unmount = null;
    },
  };
}

/** Clear what one test leaves in the browser for the next. */
export function freshBrowser(): void {
  localStorage.clear();
  sessionStorage.clear();
  history.replaceState(null, "", "/");
  document.documentElement.removeAttribute("data-mode");
}
