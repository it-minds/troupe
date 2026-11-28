// An agent's publication at the approval gate (troupe #1238): what it is (title, kind, file
// count) and who would read it. A new version keeps who reads the artifact, so the gate says
// who does and allows at once, asking nothing; a new artifact's gate is its sharing menu: the
// teams the plane named (those granted the session's profile) ticked, the person's other
// teams unticked, the organisation switch, and whose it is. Allow sends the set, Deny sends
// nothing, and letting it publish unasked is offered only where there is something to allow
// again. The record of the answer says who reads it and what was changed.

import { afterEach, describe, expect, it } from "vitest";
import type { Entry, GateAnswer } from "@troupe/client";
import { offeredTeams, publishAnswer } from "@troupe/client";
import { ApprovalPanel, DecisionRecord } from "../src/views/Approval";
import { button, enabled, render, says, sees, seesButton, waitFor } from "./support";

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
    publication: { title: "Weekly figures", kind: "html", files: 3, visibility: null, teams: ["clinics", "billing"], owner: null, id: null, access: null, note: null, ...over },
  };
}

const audiences = { teams: ["core", "billing"], organisation: true };

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

const box = (label: string): HTMLInputElement | null => [...document.querySelectorAll<HTMLLabelElement>(".audience-choices label")].find((l) => l.textContent?.trim().startsWith(label))?.querySelector("input") ?? null;

describe("the publication gate, for a new version", () => {
  it("asks nothing of who reads it: it says who does, and Allow is there at once and sends nothing", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated({ id: "art-1", note: "Week 44", teams: null, access: "the clinics and billing teams and 3 people; a view link" })} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));

    await sees("publish a new version of an artifact");
    await sees("the clinics and billing teams and 3 people; a view link, as now");
    await sees("Week 44");
    expect(document.querySelector(".audience-choices")).toBeNull();
    expect(document.querySelectorAll('input[type="radio"], input[type="checkbox"]').length).toBe(0);
    const allow = await waitFor(() => enabled(button("Allow")), "Allow, at once");
    allow.click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow", {}]);
  });

  it("lets a new version publish unasked for the session, since there is something to allow again", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated({ id: "art-1", teams: null, access: "nobody else" })} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));
    (await seesButton("Allow, and let it publish unasked for this session")).click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow_session", {}]);
  });
});

describe("the publication gate, for a new artifact", () => {
  it("ticks the teams the plane named, leaves the person's other teams unticked, and allows the set as it stands", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));

    await waitFor(() => says("Publish this?"), "the gate's question");
    await sees("A page, 3 files");
    expect((await waitFor(() => box("The clinics team"), "a named team")).checked).toBe(true);
    expect(box("The billing team")?.checked).toBe(true);
    expect(box("The core team")?.checked).toBe(false);
    expect(box("The whole organisation")?.checked).toBe(false);
    await sees("It will be read by the clinics and billing teams.");
    await waitFor(() => enabled(button("Allow")), "Allow, at once");

    button("Allow")!.click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow", { visibility: "private", teams: ["clinics", "billing"], owner: "me" }]);
  });

  it("carries the teams the person ticked and untoggled, the organisation switch, and a team's ownership only for one team", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} audiences={audiences} />));

    (await waitFor(() => box("The billing team"), "billing")).click();
    box("The core team")!.click();
    box("The whole organisation")!.click();
    await sees("It will be read by the whole organisation and the clinics and core teams.");
    // A team's ownership is the one team ticked: with two it cannot be chosen.
    expect(box("A team's, every member its owner")?.disabled).toBe(true);
    box("The core team")!.click();
    (await waitFor(() => box("The clinics team's"), "one team's ownership")).click();
    button("Allow")!.click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["allow", { visibility: "organisation", teams: ["clinics"], owner: "team" }]);
  });

  it("offers only the person and the organisation where no team is known, says so, and offers no allow for the session where the agent named nobody", async () => {
    const { answers, onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated({ teams: null })} canAnswer others={[]} onAnswer={onAnswer} audiences={null} />));
    await sees("No team of yours is known here");
    await sees("Only you will read it.");
    expect(button("Allow, and let it publish unasked for this session")).toBeNull();
    (await seesButton("Deny")).click();
    await waitFor(() => answers.length === 1, "the answer");
    expect(answers[0]).toEqual(["deny", {}]);
  });

  it("leaves the organisation out where only a platform admin may publish to it, unless the agent proposed it", async () => {
    const { onAnswer } = answering();
    ({ unmount } = render(<ApprovalPanel entry={gated()} canAnswer others={[]} onAnswer={onAnswer} audiences={{ teams: ["core"], organisation: false }} />));
    await sees("Only a platform admin may publish to the whole organisation here.");
    expect(box("The whole organisation")).toBeNull();
    unmount?.();
    ({ unmount } = render(<ApprovalPanel entry={gated({ visibility: "organisation" })} canAnswer others={[]} onAnswer={onAnswer} audiences={{ teams: ["core"], organisation: false }} />));
    expect((await waitFor(() => box("The whole organisation"), "the proposal kept")).checked).toBe(true);
  });

  it("is a record of who reads it once it is answered", async () => {
    const answered: Approval = { ...gated(), decision: "allow", answered: { visibility: "private", teams: ["clinics"], owner: "team", edited: ["teams"] } };
    ({ unmount } = render(<DecisionRecord entry={answered} self={undefined} />));
    await waitFor(() => says("read by the clinics team, the team's"), "the readers recorded");
    await sees("edited teams");
  });

  it("orders the named teams first, then the person's others; and a team's ownership needs one team", () => {
    expect(offeredTeams({ teams: ["clinics", "billing"] }, audiences.teams)).toEqual(["clinics", "billing", "core"]);
    expect(offeredTeams({ teams: null }, [])).toEqual([]);
    expect(publishAnswer({ organisation: false, teams: ["a", "b"], owner: "team" })).toEqual({ visibility: "private", teams: ["a", "b"], owner: "me" });
  });
});
