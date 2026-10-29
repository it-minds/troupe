// A direct plane's Trigger resources on the Triggers page: listed beside the team's rows as
// in the repository, with their generation and whether they pass; Copy makes the row and
// shows a webhook's key once; a copied row says where it stands (from the repository,
// repository changed with the diff and Re-copy, differs from the repository, gone from the
// repository). Against the fake plane's `admin.triggers.repository` and `admin.trigger.copy`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, freshBrowser, render, says, sees, signedInAs, startFake, visit, waitFor } from "./support";
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

const card = (resource: string): HTMLElement | null => document.querySelector<HTMLElement>(`.in-repository[aria-label="${resource}"]`);
const row = (name: string): HTMLTableRowElement | null =>
  [...document.querySelectorAll<HTMLTableRowElement>("table.triggers tbody tr")].find((r) => (r.cells[0]?.textContent ?? "") === name) ?? null;
const trigger = (team: string, name: string) => fake.admin.triggerRows.find((t) => t.team === team && t.name === name);

const review = { principal: "svc:core/nightly", profile: "dev", source: { kind: "webhook", provider: "generic" }, prompt_template: "Review what changed." };

async function open(hash: string, who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

describe("a direct plane's Trigger resources", () => {
  it("are listed beside the team's rows, with their generation and whether they pass", async () => {
    fake.admin.applyTrigger("core.nightly-review", review);
    fake.admin.applyTrigger("core.gpu-sweep", { ...review, profile: "gpu" }, ["the team core is not granted the profile gpu: grant it first (admin.team.grant)"]);
    await open("#/triggers/core");
    await waitFor(() => card("core.nightly-review"), "the resources in the repository");
    await sees("In the repository");
    await sees("generation 1", () => card("core.nightly-review"));
    await sees("passes", () => card("core.nightly-review"));
    await sees("by a webhook from generic", () => card("core.nightly-review"));
    await sees("would be refused", () => card("core.gpu-sweep"));
    await sees("the team core is not granted the profile gpu", () => card("core.gpu-sweep"));
    // One that would be refused offers no copy, and nothing is a row yet.
    expect(button("Copy gpu-sweep")).toBeNull();
    expect(trigger("core", "nightly-review")).toBeUndefined();
  });

  it("is copied after a preview, and a webhook's key is shown once", async () => {
    fake.admin.applyTrigger("core.nightly-review", review);
    await open("#/triggers/core");
    (await waitFor(() => button("Copy nightly-review"), "the copy button")).click();
    await waitFor(() => says("becomes a trigger of core, made from the resource core.nightly-review at generation 1"), "the preview");
    button("Copy nightly-review", document.querySelector(".preview")!)!.click();
    await waitFor(() => says("Recorded in the audit as trigger.copy on core/nightly-review"), "the audit's note");
    await waitFor(() => document.querySelector(".key-once"), "the key, once");
    const made = trigger("core", "nightly-review")!;
    expect(made.copied_from).toBe("core.nightly-review");
    expect(made.copied_generation).toBe(1);
    await sees(made.key!, () => document.querySelector(".key-once"));
    await waitFor(() => row("nightly-review"), "the new row");
    await sees("from the repository, generation 1", () => row("nightly-review"));
  });

  it("reads repository changed with the diff, and a re-copy brings the row up to it", async () => {
    fake.admin.applyTrigger("core.nightly-review", review);
    await signedInAs(fake, PEOPLE.alice);
    await fake.admin.call(PEOPLE.alice.subject, "admin.trigger.copy", { resource: "core.nightly-review" });
    const id = trigger("core", "nightly-review")!.id;
    fake.admin.applyTrigger("core.nightly-review", { ...review, prompt_template: "Review last week." });
    visit("#/triggers/core");
    unmount = render(<App />).unmount;

    await waitFor(() => row("nightly-review") && says("repository changed", row("nightly-review")!), "the row's state");
    await sees("Copied at generation 1; the repository is at 2", () => card("core.nightly-review"));
    await sees("Review last week.", () => card("core.nightly-review"));
    (await waitFor(() => button("Re-copy nightly-review"), "the re-copy button")).click();
    await waitFor(() => says("keeps its URL, key, runs and revisions"), "the preview");
    button("Re-copy nightly-review", document.querySelector(".preview")!)!.click();
    await waitFor(() => says("Recorded in the audit as trigger.copy on core/nightly-review"), "the audit's note");
    await waitFor(() => says("from the repository, generation 2", row("nightly-review") ?? document.body), "the row, copied again");
    const t = trigger("core", "nightly-review")!;
    expect(t.id).toBe(id);
    expect(t.prompt_template).toBe("Review last week.");
    expect(t.revisions.length).toBe(2);
    expect(document.querySelector(".key-once")).toBeNull();
  });

  it("says a row edited in the console differs, and one whose resource went is gone", async () => {
    fake.admin.applyTrigger("core.nightly-review", review);
    fake.admin.applyTrigger("core.weekly-review", { ...review, source: { kind: "manual" } });
    await signedInAs(fake, PEOPLE.alice);
    await fake.admin.call(PEOPLE.alice.subject, "admin.trigger.copy", { resource: "core.nightly-review" });
    await fake.admin.call(PEOPLE.alice.subject, "admin.trigger.copy", { resource: "core.weekly-review" });
    await fake.admin.call(PEOPLE.alice.subject, "admin.trigger.put", { trigger: { team: "core", name: "nightly-review", prompt_template: "Edited here." } });
    fake.admin.removeTrigger("core.weekly-review");
    visit("#/triggers/core");
    unmount = render(<App />).unmount;

    await waitFor(() => row("nightly-review") && says("differs from the repository", row("nightly-review")!), "the edited row");
    await sees("What a re-copy puts back", () => card("core.nightly-review"));
    await sees("gone from the repository", () => row("weekly-review"));
    await sees("goes on running until it is deleted", () => card("core.weekly-review"));
    expect(trigger("core", "weekly-review")!.enabled).toBe(true);
  });

  it("is not asked for on a gitops plane, whose triggers follow the cluster", async () => {
    fake.admin.mode = "gitops";
    fake.admin.applyTrigger("core.nightly-review", review);
    await open("#/triggers/core");
    await waitFor(() => row("nightly-deps"), "core's triggers");
    expect(says("In the repository")).toBe(false);
    expect(button("Copy nightly-review")).toBeNull();
  });
});
