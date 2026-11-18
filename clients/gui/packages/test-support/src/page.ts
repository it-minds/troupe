// What both apps' tests need that a browser would have: a page to render into, a way to
// find a control and press or type into it, and a way to wait for what a later render
// draws. Each app's `test/support.ts` re-exports these beside what is its own.
//
// No testing library. An app is driven the way a person drives it: find the button by
// what it says, press it, wait until the screen says something. That is a page of code
// rather than a dependency.

import { createRoot } from "react-dom/client";
import type { ReactElement } from "react";

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
 * throws has not found it yet: an element it reaches into can be gone for a render while
 * the screen redraws it. At the deadline the last thing it threw is said.
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

/** Whether the page, or `within`, says this anywhere. */
export function says(text: string, within: ParentNode = document.body): boolean {
  return (within.textContent ?? "").includes(text);
}

/**
 * Wait until the page says this. The assertion for anything that shows after an async
 * step: a line drawn by another render than the one a `waitFor` saw is not there yet in
 * the same tick, on a busy machine. `expect(says(…)).toBe(true)` is refused by each app's
 * `waits.test.tsx` unless its line says why it is meant at once (`// at once: <why>`).
 */
export async function sees(text: string, within: ParentNode | (() => ParentNode | null | undefined) = document.body): Promise<void> {
  // A function is asked again on every look: the row it finds can be drawn anew meanwhile.
  await waitFor(() => {
    const at = typeof within === "function" ? within() : within;
    return Boolean(at) && says(text, at!);
  }, `the page to say "${text}"`);
}

/** The button whose words begin with `label`, inside `within` if given. */
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

/**
 * The control if it is there and may be used, else null. A control is drawn before it is
 * enabled as often as not (a menu item waiting on the plane, a button on a form being
 * checked), so a wait for one that is to be pressed or said to be enabled waits for this.
 */
export function enabled<T extends { disabled: boolean }>(control: T | null | undefined): T | null {
  return control && !control.disabled ? control : null;
}

/** Wait for the button whose words begin with `label` to be there and enabled, and answer it. */
export function seesEnabled(label: string, within: ParentNode = document): Promise<HTMLButtonElement> {
  return waitFor(() => enabled(button(label, within)), `the button "${label}", enabled`);
}

/** Type into a field, or choose in a select, the way React hears it: the native setter, then the event. */
export function type(el: HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement, value: string): void {
  const proto = el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(el, value);
  el.dispatchEvent(new Event(el instanceof HTMLSelectElement ? "change" : "input", { bubbles: true }));
}
