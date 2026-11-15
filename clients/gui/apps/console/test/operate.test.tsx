// Operate: the pods behind each profile, drained by typing the pod's name, and the
// manifests for a repository; what each provisioner guarantees, and the machines
// registered to run workers, registered, rotated and switched off with their secret and CA
// shown once. Against the fake plane's `admin.pod.drain`, `admin.profiles.export`,
// `admin.provisioners.list` and `admin.host*`, as a platform admin, whose areas these are.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { pod } from "../../../packages/client/test/support/admin.js";

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

async function open(hash: string, who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

const row = (first: string): HTMLTableRowElement | null => [...document.querySelectorAll<HTMLTableRowElement>("tr")].find((r) => r.cells[0]?.textContent === first) ?? null;
const go = (verb: string) => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith(verb) && !b.disabled);

describe("workers and pods", () => {
  it("lists each profile's pods, and drains one once its name is typed", async () => {
    await open("#/pods");
    await waitFor(() => row("troupe-w-dev-0"), "dev's pods");
    await sees("healthy", () => row("troupe-w-dev-0"));
    await sees("draining", () => row("troupe-w-dev-1"));
    await sees("unknown", () => row("build-box-0"));
    // A draining pod is not offered a second drain.
    expect(button("Drain", row("troupe-w-dev-1")!)).toBeNull();

    button("Drain", row("troupe-w-dev-0")!)!.click();
    // dev's only other pod is draining itself, so nothing can take what this one holds.
    await waitFor(() => says("Its 3 sessions are interrupted and sealed"), "the preview");
    await sees("No other pod can take them; they will wait for one.");
    expect(says("opened again on")).toBe(false);
    expect(go("Drain")).toBeUndefined();
    type(field("Type troupe-w-dev-0 to confirm")!, "troupe-w-dev-0");
    (await waitFor(() => go("Drain"), "the name typed")).click();
    await waitFor(() => says("Recorded in the audit as pod.drain on troupe-w-dev-0"), "the audit's note");
    await sees("troupe-w-dev-0 held 3 sessions: 3 moved.");
    expect(fake.admin.profiles.find((p) => p.name === "dev")!.pods[0]!.draining).toBe(true);
  });

  it("names the pod a drain moves sessions to, counting only one that can take them", async () => {
    const dev = fake.admin.profiles.find((p) => p.name === "dev")!;
    dev.pods.push(pod("troupe-w-dev-2", 2, { healthy: false }), pod("troupe-w-dev-3", 3));
    await open("#/pods");
    (await waitFor(() => row("troupe-w-dev-0") && button("Drain", row("troupe-w-dev-0")!), "dev's pods")).click();
    // dev-1 is draining and dev-2 is broken: dev-3 is the one pod that can take them.
    await waitFor(() => says("Its 3 sessions are moved: each is interrupted, sealed and opened again on troupe-w-dev-3, and a turn in flight is cancelled."), "the preview");
    expect(says("other pods that can take them")).toBe(false);
  });

  it("says a pod a scale-down removed is gone, since when, offers it nothing and counts it nowhere (troupe #883)", async () => {
    // The fake's ux-1 was retired a month ago. Its flags here are as the pod last reported
    // them, healthy and not draining, and it is still gone and no place for sessions to go.
    const ux = fake.admin.profiles.find((p) => p.name === "ux")!;
    Object.assign(ux.pods[1]!, { healthy: true, draining: false });
    await open("#/pods");
    await waitFor(() => row("troupe-w-ux-1"), "ux's pods");
    await sees("gone 2026-09-14 10:02 UTC", () => row("troupe-w-ux-1")!.cells[1]!);
    // at once: the row is drawn whole once its state is
    const state = row("troupe-w-ux-1")!.cells[1]!.textContent ?? "";
    expect(state.includes("draining") || state.includes("healthy")).toBe(false);
    expect(button("Drain", row("troupe-w-ux-1")!)).toBeNull();

    button("Drain", row("troupe-w-ux-0")!)!.click();
    await waitFor(() => says("Its 2 sessions are interrupted and sealed"), "the preview");
    await sees("No other pod can take them; they will wait for one.");
    expect(says("opened again on troupe-w-ux-1")).toBe(false);
  });

  it("says a pod in the singular, an image that is not there in words, and an ssh host as a machine", async () => {
    await open("#/pods");
    const section = (name: string) => document.querySelector<HTMLElement>(`section[aria-label="${name}"]`);
    await waitFor(() => section("ux's pods"), "ux's pods");
    await sees("ux · 1 of 1 pod", () => section("ux's pods"));
    await sees("heavy · 1 of 2 pods", () => section("heavy's pods"));
    // build-box is an ssh host with no image: a machine, as Hosts calls it, and no dash in a sentence.
    const box = () => section("build-box's machines");
    await sees("build-box · 1 of 1 machine", box);
    await sees("build-box has no image yet, following the stable channel; 0 of 2 sessions in use.", box);
    expect(box()!.textContent).not.toContain("runs —");
    expect(box()!.querySelector("th")!.textContent).toBe("Machine");
  });

  it("shows every profile, the policy and every trigger as a repository would hold them", async () => {
    await open("#/pods");
    (await waitFor(() => button("Show the manifests"), "the manifests' button")).click();
    await waitFor(() => says("profiles/dev.yaml"), "the manifests");
    await sees("policy/troupe.yaml");
    await sees("triggers/core/nightly-deps.yaml");
    await sees("kind: Trigger");
    await sees("spec.replicas");
  });
});

describe("provisioners and hosts", () => {
  it("names each guarantee a substrate does not give, and what a profile's workers lack", async () => {
    await open("#/hosts");
    await waitFor(() => row("kubernetes"), "the provisioners");
    await sees("egress by hostname", () => row("kubernetes"));
    await sees("the egress allowlist checked at admission, not on the wire", () => row("kubernetes"));
    await sees("admission policy, network policy, egress by hostname, disruption budget", () => row("ssh"));
    await waitFor(() => says("everything is enforced", row("dev")!), "dev");
    await sees("not enforced", () => row("build-box"));
    await sees("No team may be granted a profile nothing is enforced on");
  });

  it("registers a machine with its secret and CA shown once, rotates it by name, and switches it off", async () => {
    await open("#/hosts");
    await waitFor(() => row("build-box-0"), "build-box's machines");
    await sees("enrolled", () => row("build-box-0"));
    await sees("never seen", () => row("build-box-1"));

    button("Register a machine to build-box")!.click();
    type(await waitFor(() => field("Name"), "the form"), "build-box-2");
    type(field("Address")!, "10.20.0.16");
    button("Preview")!.click();
    (await waitFor(() => go("Register"), "the preview")).click();
    await waitFor(() => says("build-box-2's enrolment secret, shown once"), "the secret");
    await sees("BEGIN CERTIFICATE");
    await waitFor(() => row("build-box-2"), "the machine listed");
    await sees("never seen", () => row("build-box-2"));
    expect(JSON.stringify(fake.admin.audit)).not.toMatch(/wh_/);

    button("Rotate", row("build-box-0")!)!.click();
    type(await waitFor(() => field("Type build-box-0 to confirm"), "the typed confirmation"), "build-box-0");
    (await waitFor(() => go("Rotate"), "the name typed")).click();
    await waitFor(() => says("build-box-0's enrolment secret, shown once"), "the new secret");

    (await waitFor(() => button("Switch off", row("build-box-1")!), "the list again")).click();
    await waitFor(() => says("build-box-1's next enrolment is refused"), "the preview");
    (await waitFor(() => go("Switch off"), "the confirm")).click();
    await waitFor(() => says("switched off", row("build-box-1")!), "the machine off");
    expect(fake.admin.hostRows.find((h) => h.name === "build-box-1")!.enabled).toBe(false);
  });
});
