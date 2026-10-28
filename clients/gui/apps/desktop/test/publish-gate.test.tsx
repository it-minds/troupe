// An agent's publication at the approval gate: what it is (title, kind, file count) and
// whom it is for as a choice among the person's audiences, the agent's proposal chosen
// already and nothing chosen where it proposed nobody; Allow sends the choice, Deny sends
// nothing, and letting it publish unasked is offered only with a proposal. The record of
// the answer says whom it went to and what was changed.

import { afterEach, describe, expect, it } from "vitest";
import type { Entry, GateAnswer } from "@troupe/client";
import { ApprovalPanel, DecisionRecord, audienceChoices } from "../src/views/Approval";
import { button, render, says, sees, seesButton, waitFor } from "./support";

type Approval = Extract<Entry, { kind: "approval" }>;

function gated(over: Partial<Approval["publication"] & object> = {}): Approval {
  return {
    kind: "approval",
    seq: 4,
    agent: ["root"],
    callId: "publish-1",
    tool: "publish_artifact",
    args: { title: "Weekly figures" },
    decision: undefined,
    resolvedBy: undefined,
    closed: false,
    publication: { title: "Weekly figures", kind: "html", files: 3, visibility: "team:core", owner: "team", id: null, note: null, ...over },
  };
}

const audiences = { teams: ["core", "design"], profiles: ["dev"] };

let unmount: (() => void) | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
});

function answering(): { answers: Array<[string, GateAnswer | undefined]>; onAnswer: (d: string, a?: GateAnswer) => Promise<void> } {
  const answers: Array<[string, GateAnswer | undefined]> = [];
  return {
    answers,
    onAnswer: async (d, a) => {
      answers.push([d, a]);
    },
  };
}

const radio = (label: string): HTMLInputElement | null => [...document.querySelectorAll<HTMLLabelElement>(".audience-choices label")].find((l) => l.textContent?.trim() === label)?.querySelector("input") ?? null;

describe("the publication gate", () => {
  it("shows the publication with the proposal chosen, and allows it as proposed", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));

    await waitFor(() => says("Publish this?"), "the gate's question");
    await sees("Weekly figures");
    await sees("A page, 3 files");
    const chosen = await waitFor(() => radio("Team core, owned by the team"), "the proposal");
    expect(chosen.checked).toBe(true);
    expect(radio("Team core, owned by you")?.checked).toBe(false);
    expect(radio("The dev profile's people")).not.toBeNull();

    (await seesButton("Allow")).click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow", { visibility: "team:core", owner: "team" }]);
  });

  it("waits for a choice where the agent proposed nobody, and offers no allow for the session", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated({ visibility: null, owner: null })} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));

    await sees("The agent did not say whom it is for.");
    expect((await seesButton("Allow")).disabled).toBe(true);
    expect(button("Allow, and let it publish unasked for this session")).toBeNull();

    (await waitFor(() => radio("Only you"), "the private choice")).click();
    await waitFor(() => !button("Allow")!.disabled, "Allow enabled");
    button("Allow")!.click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow", { visibility: "private", owner: "me" }]);
  });

  it("keeps a team's artifact the person's own instead, says what was proposed, and lets it publish unasked", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));

    (await waitFor(() => radio("Team core, owned by you"), "the person's own choice")).click();
    await sees("The agent proposed team core, owned by the team.");
    (await seesButton("Allow, and let it publish unasked for this session")).click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow_session", { visibility: "team:core", owner: "me" }]);
  });

  it("denies with nothing else, and offers the proposal while the audiences are still unknown", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated({ visibility: "profile:ux", owner: null })} canAnswer others={[]} onAnswer={onAnswer} audiences={null} />));

    const proposed = await waitFor(() => radio("The ux profile's people"), "the proposal, though the plane has not named the profile yet");
    expect(proposed.checked).toBe(true);
    (await seesButton("Deny")).click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["deny", {}]);
  });

  it("is a record of whom it went to once it is answered", async () => {
    const answered: Approval = { ...gated(), decision: "allow", answered: { visibility: "team:core", owner: "team", edited: ["owner"] } };
    ({ unmount } = render(<DecisionRecord entry={answered} self={undefined} />));
    await waitFor(() => says("for the core team, the team's"), "the audience recorded");
    await sees("edited owner");
  });

  it("asks only whom a new version is for, and sends no owner", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated({ id: "art-1", note: "Week 44", visibility: "team:core", owner: null })} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));

    await sees("publish a new version of an artifact");
    await sees("Week 44");
    const team = await waitFor(() => radio("Team core"), "one choice a team");
    expect(team.checked).toBe(true);
    expect(radio("Team core, owned by the team")).toBeNull();
    (await seesButton("Allow")).click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow", { visibility: "team:core" }]);
  });

  it("offers each team twice, each profile once, and the proposal besides", () => {
    const keys = audienceChoices(audiences, { visibility: "team:ops", owner: null }).map((c) => c.key);
    expect(keys).toEqual(["private|me", "organisation|me", "team:core|team", "team:core|me", "team:design|team", "team:design|me", "profile:dev|me", "team:ops|team"]);
    expect(audienceChoices(audiences, { visibility: "team:ops", owner: null }, true).map((c) => c.key)).toEqual(["private", "organisation", "team:core", "team:design", "profile:dev", "team:ops"]);
  });
});
