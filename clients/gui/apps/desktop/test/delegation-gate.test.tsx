// A delegation a person asked to see first, in the approval panel (troupe Decision 850):
// the agent and a way to its definition, the tools the subagent will hold, its depth and
// budget, the brief's five parts, and the five answers — run, edit a part in place, send it
// to another subagent, deny with a word back, and let that agent run unasked.

import { afterEach, describe, expect, it } from "vitest";
import type { Entry, GateAnswer } from "@troupe/client";
import { ApprovalPanel, DecisionRecord } from "../src/views/Approval";
import { button, render, says, sees, type, waitFor } from "./support";

type Approval = Extract<Entry, { kind: "approval" }>;

function gated(): Approval {
  return {
    kind: "approval",
    seq: 4,
    agent: ["root"],
    callId: "call_7",
    tool: "delegate",
    args: {},
    decision: undefined,
    resolvedBy: undefined,
    closed: false,
    delegation: {
      agent: "general",
      definition: { name: "general", layer: "builtin", path: "/agents/general.md", description: "Edits code." },
      brief: { goal: "Write notes.md", context: "none", constraints: "none", deliverable: "a summary", do_not: "none" },
      tools: [
        { name: "read_file", permission: "auto" },
        { name: "write_file", permission: "ask" },
      ],
      budgetShare: 0.5,
      depth: 1,
      maxDepth: 3,
      agents: [
        { name: "explore", description: "Reads." },
        { name: "general", description: "Edits code." },
      ],
    },
  };
}

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

describe("the delegation gate", () => {
  it("shows the whole delegation, and opens the definition rather than editing it", async () => {
    const opened: string[] = [];
    ({ unmount } = render(
      <ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={async () => undefined} onDefinition={(a) => opened.push(a)} />,
    ));

    await waitFor(() => says("Hand this to general?"), "the gate's question");
    for (const part of ["Write notes.md", "Goal", "Context", "Constraints", "Deliverable", "Do not"]) await sees(part);
    await sees("1 of 3");
    await sees("50% of the budget");
    await sees("write_file ask");

    button("Open its definition")!.click();
    expect(opened).toEqual(["general"]);
  });

  it("edits a part in place, holds the shape, and runs with the edit", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} />));

    const edit = await waitFor(() => document.querySelector<HTMLButtonElement>("button[aria-label='Edit Constraints']"), "the edit button");
    edit.click();
    const field = await waitFor(() => document.querySelector<HTMLTextAreaElement>("textarea[aria-label='Edit Constraints']"), "the part's field");
    expect(field.value).toBe("none");

    type(field, "  ");
    button("Keep")!.click();
    await waitFor(() => says("cannot be empty"), "an empty part refused");

    type(field, "Touch notes.md and nothing else.");
    button("Keep")!.click();
    await waitFor(() => says("Constraints · edited"), "the part marked edited");

    button("Run")!.click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow", { brief: { constraints: "Touch notes.md and nothing else." } }]);
  });

  it("sends the same brief to another subagent, and lets it run unasked for the session", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} />));

    const to = await waitFor(() => document.querySelector<HTMLSelectElement>("select[aria-label='Send to']"), "the agent chooser");
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(to, "explore");
    to.dispatchEvent(new Event("change", { bubbles: true }));
    await waitFor(() => says("Hand this to explore?"), "the switch shown");

    button("Run, and let explore run unasked")!.click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow_session", { agent: "explore" }]);
  });

  it("denies with a word back", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} />));

    (await waitFor(() => button("Deny…"), "the deny button")).click();
    const word = await waitFor(() => document.querySelector<HTMLInputElement>("input[aria-label='A word back']"), "the word back");
    type(word, "look with explore first");
    button("Deny")!.click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["deny", { reason: "look with explore first" }]);
  });

  it("is a record of what the answer changed once it is answered", async () => {
    const answered: Approval = { ...gated(), decision: "allow", answered: { agent: "explore", edited: ["constraints"] } };
    ({ unmount } = render(<DecisionRecord entry={answered} self={undefined} />));
    await waitFor(() => says("sent to explore"), "the switch recorded");
    await sees("edited constraints");
  });
});
