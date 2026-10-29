// Driving a real Dex and a real plane headlessly, for the tests that run against one
// (`e2e.plane.test.ts`, `e2e.plane-light.test.ts`): a device code approved the way a
// person would, and a plane waited for the way a client does.

import assert from "node:assert/strict";
import { PlaneClient } from "../../src/index.js";
import type { DeviceAuthorization, Discovery } from "../../src/index.js";

/**
 * Approve a device code at Dex the way a person would: type the code, sign in, and let
 * the approval screen be skipped. Three form posts and a redirect chain — doing it here
 * is what makes "sign in" a test rather than something somebody has to sit through.
 */
export async function approveAtDex(
  issuer: string,
  device: DeviceAuthorization,
  user: string,
  password: string,
): Promise<void> {
  const base = new URL(issuer);
  const abs = (loc: string) => new URL(loc.replace(/&amp;/g, "&"), base).href;
  const form = { "content-type": "application/x-www-form-urlencoded" };

  let res = await fetch(abs("/dex/device/auth/verify_code"), {
    method: "POST",
    redirect: "manual",
    headers: form,
    body: new URLSearchParams({ user_code: device.user_code }),
  });

  // Follow the chain until a page renders; that page is the login form.
  let location = res.headers.get("location");
  let body = "";
  for (let hop = 0; hop < 8 && location; hop++) {
    res = await fetch(abs(location), { redirect: "manual" });
    location = res.headers.get("location");
    if (!location) body = await res.text();
  }
  assert.ok(body.includes('name="password"'), "reached Dex's login form");

  const action = /<form[^>]*action="([^"]+)"/.exec(body)?.[1];
  assert.ok(action, "the login form has an action");
  res = await fetch(abs(action), {
    method: "POST",
    redirect: "manual",
    headers: form,
    body: new URLSearchParams({ login: user, password }),
  });

  // …and on through the approval and the device callback.
  location = res.headers.get("location");
  for (let hop = 0; hop < 8 && location; hop++) {
    res = await fetch(abs(location), { redirect: "manual" });
    location = res.headers.get("location");
  }
  assert.ok(res.status < 400, `the device code was approved (last status ${res.status})`);
}

/**
 * The plane's discovery document, once the plane answers. A plane is up when it answers,
 * not when its container is running: `docker compose up --wait` returns as soon as the
 * container starts, because the plane has no health check it could run
 * (dev/plane-stack.yml says why), and the release listens a few seconds later. Asked
 * before then, Docker's port proxy accepts the connection and closes it. So the suite
 * waits the way a client would, by asking again.
 */
export async function waitForPlane(plane: string, timeoutMs = 180_000): Promise<Discovery> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      return await new PlaneClient(plane).discover();
    } catch (error) {
      if (Date.now() > deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
  }
}
