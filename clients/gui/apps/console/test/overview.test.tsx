// The overview: what needs attention first, worst first and each with where it is fixed;
// then each profile's fleet and each team's spend. From `admin.overview`, with the runs
// nobody has read from `admin.sessions.list`, scoped by the plane to what the person
// administers.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, freshBrowser, link, render, says, sees, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const items = (): HTMLElement[] => [...document.querySelectorAll<HTMLElement>("ul.attention li")];
const metric = (label: string): HTMLElement | null => [...document.querySelectorAll<HTMLElement>(".metric")].find((m) => says(label, m)) ?? null;

describe("the overview", () => {
  it("is where the console opens, and says what needs attention first, worst first, each with where it is fixed", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => items().length > 0, "what needs attention");
    expect(document.querySelector("h1")?.textContent).toBe("Overview");

    const said = items().map((i) => i.textContent ?? "");
    // design is over its ceiling; build-box-0 never reported; heavy has one pod of two;
    // dev-1 drains; one trigger run waits to be read.
    expect(said[0]).toContain("design is at its monthly ceiling");
    expect(said.some((s) => s.includes("troupe-w-dev-1 on dev is draining: 1 session still on it."))).toBe(true);
    expect(said.some((s) => s.includes("build-box-0 on build-box has never reported"))).toBe(true);
    expect(said.some((s) => s.includes("heavy asked for 2 pods and has 1."))).toBe(true);
    expect(said.some((s) => s.includes("1 session an unattended run started is waiting for a person"))).toBe(true);
    expect(link("design's limits")!.getAttribute("href")).toBe("#/teams/design/limits");
    // Each is fixed in this console: a pod where the pods are, the runs where runs are read.
    expect(link("Look at heavy")!.getAttribute("href")).toBe("#/pods");
    expect(link("Runs and review")!.getAttribute("href")).toBe("#/runs");
    expect([...document.querySelectorAll("a")].filter((a) => a.href.includes("/admin"))).toEqual([]);

    await sees("4", () => metric("Active sessions"));
    await sees("5 dormant, 1 read-only", () => metric("Active sessions"));
    await sees("3 / 5", () => metric("Pods"));
    await sees("473.50", () => metric("Spent"));
  });

  it("shows each profile's fleet and each team's spend against its budget", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/overview");
    unmount = render(<App />).unmount;
    await waitFor(() => says("Fleet · per profile") && link("build-box"), "the fleet");
    // A profile is linked to its own page in this console.
    expect(link("build-box")!.getAttribute("href")).toBe("#/profiles/build-box");
    await sees("over budget");
    expect(link("core")!.getAttribute("href")).toBe("#/teams/core/limits");
  });

  it("shows a team admin their own team's part and nothing of another's", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => says("Spend · per team") && link("design"), "the overview, as the design team's admin");
    expect(link("core")).toBeNull();
    expect(link("dev")).toBeNull();
    await sees("2 dormant, 0 read-only", () => metric("Active sessions"));
  });

  it("says so when nothing needs attention", async () => {
    for (const p of fake.admin.profiles) p.pods = Array.from({ length: p.replicas }, (_, i) => ({ ...p.pods[0]!, pod: `${p.name}-${i}`, healthy: true, draining: false, last_seen_at: "2026-10-13T09:00:00Z" }));
    for (const t of fake.admin.teams.values()) t.budget_micros = 0;
    for (const s of fake.admin.sessions) s.reviewed = true;
    fake.admin.seen.splice(0);
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("Nothing needs attention"), "the empty list");
    await sees("Nothing is unhealthy, at its ceiling or waiting on a person.");
  });

  // #657: the clients the plane last saw behind the recommended version, as one line, and
  // none where there are none.
  it("says how many clients are behind the recommended version, and where to look", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => items().length > 0, "what needs attention");
    await sees("3 clients behind the recommended version, 2 of them refused when they next connect.");
    const line = items().find((i) => says("behind the recommended version", i))!;
    expect(line.querySelector("a")?.textContent).toBe("Client versions");
    expect(line.querySelector("a")?.getAttribute("href")).toBe("#/clients");
  });

  // What the operator reports on a profile and nothing else may: a Secret its pods mount
  // that the namespace has no copy of, and no namespace the ingress controller may reach a
  // worker from, which is the cluster's and so one line however many profiles say it.
  it("names a missing Secret per profile, and an unlabelled ingress namespace once, with the line that fixes it", async () => {
    const ingress = {
      type: "IngressNamespaceMissing",
      status: "True",
      reason: "NoNamespaceLabelled",
      message: "no namespace carries troupe.dev/ingress=true, so no ingress controller may reach a worker: kubectl label namespace ingress-nginx troupe.dev/ingress=true",
    };
    for (const p of fake.admin.profiles) p.conditions = [...(p.conditions ?? []), ingress];
    const ux = fake.admin.profiles.find((p) => p.name === "ux")!;
    ux.conditions!.push({
      type: "SecretMissing",
      status: "True",
      reason: "SecretsMissing",
      message: "missing secret(s): llm-key (in troupe-system without troupe.dev/worker-secret=true, which lets the operator copy it to workers: kubectl -n troupe-system label secret llm-key troupe.dev/worker-secret=true)",
    });

    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => items().some((i) => says("kubectl label namespace ingress-nginx", i)), "the ingress namespace among what needs attention");
    expect(items().filter((i) => says("troupe.dev/ingress=true", i))).toHaveLength(1);
    const secret = items().find((i) => says("ux: missing secret(s): llm-key", i));
    expect(secret?.textContent).toContain("kubectl -n troupe-system label secret llm-key troupe.dev/worker-secret=true");
    expect(secret?.querySelector("a")?.getAttribute("href")).toBe("#/pods");
  });

  it("says nothing of a condition that does not hold", async () => {
    for (const p of fake.admin.profiles) {
      p.conditions = [
        { type: "SecretMissing", status: "False", reason: "SecretsPresent", message: "every secret the pods mount is in the worker namespace" },
        { type: "IngressNamespaceMissing", status: "False", reason: "Labelled", message: "ingress-nginx carries troupe.dev/ingress=true and runs pods" },
      ];
    }
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => items().length > 0, "what needs attention");
    expect(items().some((i) => says("troupe.dev/ingress=true", i) || says("secret", i))).toBe(false);
  });

  it("has no line about clients when none is behind", async () => {
    fake.admin.seen.splice(0, fake.admin.seen.length, ...fake.admin.seen.filter((s) => s.version === "0.16.0-beta"));
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => items().length > 0, "what needs attention");
    expect(items().some((i) => says("behind the recommended version", i))).toBe(false);
  });
});

// The plane cannot grant itself an OpenBao policy, so what its role lacks is a precondition
// it checks look-only and says, with the lines an OpenBao administrator runs (#765).
describe("the key manager", () => {
  const keyManager = (): HTMLElement | null => document.querySelector<HTMLElement>('section[aria-label="Key manager"]');

  it("lists each grant the plane's OpenBao role holds", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => keyManager(), "the key manager");
    await sees("troupe-plane-signing", keyManager);
    await sees("troupe-plane-github (optional)", keyManager);
    expect(keyManager()!.querySelector("pre")).toBeNull();
  });

  it("names a grant it lacks as needing attention, with the lines that grant it", async () => {
    const grant = fake.admin.openbao.grants.find((g) => g.id === "plane-signing")!;
    Object.assign(grant, {
      ok: false,
      detail: "The plane's OpenBao role may not make, rotate and sign with the plane's own key.",
      fix: "bao policy write troupe-plane-signing - <<'POLICY'\n...\nPOLICY\nbao write auth/kubernetes/role/troupe-plane token_policies=troupe-plane,troupe-plane-signing\n",
    });
    fake.admin.openbao.ok = false;

    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => items().some((i) => says("may not make, rotate and sign", i)), "the missing grant among what needs attention");
    await sees("To grant troupe-plane-signing, an OpenBao administrator runs:", keyManager);
    await sees("token_policies=troupe-plane,troupe-plane-signing", keyManager);
  });

  it("is not shown to a team admin, whose overview says nothing of it", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => says("Spend · per team"), "the overview, as a team admin");
    expect(keyManager()).toBeNull();
  });
});
