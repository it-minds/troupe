// The budget question's panel (troupe-remote Decision 699): the harness's own options,
// each answered with its label, and a line for an amount typed in — which is the answer
// the question is for, and what a person could not give before.

import { afterEach, describe, expect, it } from "vitest";
import type { Entry } from "@troupe/client";
import { QuestionPanel } from "../src/views/Question";
import { button, render, says, type, waitFor } from "./support";

type Question = Extract<Entry, { kind: "question" }>;

function budget(options: Question["options"]): Question {
  return {
    kind: "question",
    seq: 1,
    agent: ["root"],
    callId: "budget-1",
    question: "turns 40/40 (100%): the turn limit is a safety net against runaway loops and runaway spend.",
    options,
    multiple: false,
    asked: "budget",
    answer: undefined,
    closed: false,
  };
}

let unmount: (() => void) | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
});

describe("the budget question", () => {
  it("offers the harness's options and takes an amount typed in", async () => {
    const answers: string[] = [];
    const onAnswer = async (text: string): Promise<void> => {
      answers.push(text);
    };
    const entry = budget([
      { label: "+10 turns this run", description: "for the run in flight (about $0.30)" },
      { label: "no limit this session", description: "lift the turn limit" },
      { label: "stop", description: "stop here" },
    ]);

    ({ unmount } = render(<QuestionPanel entry={entry} canAnswer onAnswer={onAnswer} />));

    await waitFor(() => says("the turn limit is a safety net"), "the harness's words");
    const ten = await waitFor(() => button("+10 turns this run"), "the first option");
    expect(ten.title).toBe("for the run in flight (about $0.30)");
    expect(button("stop")).not.toBeNull();

    ten.click();
    await waitFor(() => answers.length === 1, "the option answered");
    expect(answers).toEqual(["+10 turns this run"]);

    const field = await waitFor(() => document.querySelector<HTMLInputElement>("input[aria-label='How much more, and for how long']"), "the amount field");
    type(field, "+50 session");
    const answer = await waitFor(() => button("Answer"), "the answer button");
    await waitFor(() => !answer.disabled, "the answer button enabled");
    answer.click();
    await waitFor(() => answers.length === 2, "the typed amount answered");
    expect(answers[1]).toBe("+50 session");
  });

  it("falls back to the three old answers when the daemon offered none", async () => {
    ({ unmount } = render(<QuestionPanel entry={budget([])} canAnswer onAnswer={async () => undefined} />));

    await waitFor(() => button("Spend one more slice"), "the old first answer");
    expect(button("Stop here")).not.toBeNull();
    expect(button("Lift this limit for the session")).not.toBeNull();
  });
});
