// The session screen's room (troupe #895): a panel that waits on the person never takes
// the transcript's last lines or hides its own answers, a backstage table breaks only its
// long tokens, and the start's onboarding line is in this app's words, never raw Markdown.
//
// jsdom lays nothing out, so what layout gives is asserted where it is decided: each
// panel's answers sit outside the part that scrolls, and the sheet the app loads gives
// the transcript a minimum, the panel's body the scroll, and the table's cells their
// wrapping. The browser measurements are in the pull request.

import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it } from "vitest";
import type { JSX } from "react";
import type { Entry, OnboardingSuggested, StartQuestion, StartState } from "@troupe/client";
import { ApprovalPanel } from "../src/views/Approval";
import { QuestionPanel } from "../src/views/Question";
import { OfferPanel } from "../src/views/Offer";
import { onboardingNote, StartPanel } from "../src/views/Onboard";
import { render, waitFor } from "./support";

// A name in a variable, so the bundler reads it as a file to open and not as an asset.
const sheet = "../src/styles.css";
const css = readFileSync(new URL(sheet, import.meta.url), "utf8");

let unmount: (() => void) | null = null;
let style: HTMLStyleElement | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
  style?.remove();
  style = null;
});

function show(element: JSX.Element): void {
  unmount = render(element).unmount;
}

const approval: Extract<Entry, { kind: "approval" }> = {
  kind: "approval",
  seq: 3,
  agent: ["root"],
  callId: "c1",
  tool: "shell",
  args: { command: "git push" },
  decision: undefined,
  resolvedBy: undefined,
  closed: false,
};

const question: Extract<Entry, { kind: "question" }> = {
  kind: "question",
  seq: 4,
  agent: ["root"],
  callId: "q1",
  question: "Which branch?",
  options: [
    { label: "main", description: null },
    { label: "dev", description: null },
  ],
  multiple: false,
  asked: "agent",
  preview: "a long prompt",
  answer: undefined,
  closed: false,
};

const item = {
  id: "p1",
  target: "workspace",
  path: "AGENTS.md",
  shown: "AGENTS.md",
  status: "new" as const,
  question: "write" as const,
  source: "CLAUDE.md",
  notes: [],
  diff: "+ # AGENTS.md",
};

const onboardAsk: StartQuestion = { kind: "onboard", due: "first", text: "Onboard 1 file?", detail: "What onboarding is.", items: [item], skipped: [] };

const startState = (asking: StartQuestion): StartState => ({ asking, busy: false, said: [], refusal: null, error: null });

describe("a panel waiting on the person", () => {
  const panels: Array<[string, () => JSX.Element]> = [
    ["an approval", () => <ApprovalPanel entry={approval} canAnswer others={[]} onAnswer={async () => undefined} />],
    ["a question", () => <QuestionPanel entry={question} canAnswer onAnswer={async () => undefined} />],
    ["the offer of your servers", () => <OfferPanel ask={{ prompt: "Let this session run 2 tools?", tools: ["a.x", "b.y"], servers: ["a", "b"], chosen: ["a", "b"] }} onAnswer={() => undefined} />],
    ["the onboarding offer", () => <StartPanel state={startState(onboardAsk)} onAnswer={() => undefined} />],
    ["a file's review", () => <StartPanel state={startState({ kind: "review", text: "Write AGENTS.md?", item, index: 1, total: 2 })} onAnswer={() => undefined} />],
  ];

  for (const [what, panel] of panels) {
    it(`keeps ${what}'s answers outside the part that scrolls`, async () => {
      show(panel());
      const section = await waitFor(() => document.querySelector<HTMLElement>(".approval"), what);
      const body = section.querySelector<HTMLElement>(":scope > .panel-body");
      expect(body, "the scrolling body").not.toBeNull();
      expect(body!.querySelector(".consequence")).not.toBeNull();
      const answers = section.querySelectorAll(":scope > .answers");
      expect(answers.length).toBeGreaterThan(0);
      expect(body!.querySelector(".answers button")).toBeNull();
      expect(section.querySelector(":scope > header h2")).not.toBeNull();
    });
  }
});

describe("the sheet", () => {
  /** The declarations of the rule whose selector list is exactly `selector`. */
  function rule(selector: string): string {
    const at = css.indexOf(`\n${selector} {`);
    expect(at, selector).toBeGreaterThan(-1);
    return css.slice(at, css.indexOf("}", at));
  }

  it("gives the transcript a minimum height in rem, and the panel no scroll of its own", () => {
    expect(rule(".conversation")).toMatch(/--transcript-min:\s*min\(\d+(\.\d+)?rem, \d+vh\);/);
    expect(rule(".stream")).toMatch(/min-height:\s*var\(--transcript-min\);/);
    // The panel is held under the column less that minimum, and its body scrolls, not it.
    expect(rule(".approval")).not.toMatch(/overflow/);
    expect(css).toMatch(/\.conversation > \.approval \{\s*max-height: calc\(100% - var\(--transcript-min\)/);
    expect(rule(".approval > .panel-body")).toMatch(/overflow-y:\s*auto;/);
  });

  it("breaks a backstage table's tokens inside themselves and its prose only between words", async () => {
    style = document.createElement("style");
    style.textContent = css;
    document.head.appendChild(style);
    show(
      <aside className="backstage">
        <table className="table">
          <tbody>
            <tr>
              <td id="prose">the session&apos;s terms</td>
              <td id="key">
                <code>models.default</code>
              </td>
              <td id="value" className="token">
                http://llm.example.test/v1
              </td>
            </tr>
          </tbody>
        </table>
      </aside>,
    );
    const prose = await waitFor(() => document.getElementById("prose"), "the table");
    expect(getComputedStyle(prose).overflowWrap).toBe("normal");
    expect(getComputedStyle(prose).wordBreak).toBe("normal");
    expect(getComputedStyle(document.querySelector("#key code")!).overflowWrap).toBe("anywhere");
    expect(getComputedStyle(document.getElementById("value")!).overflowWrap).toBe("anywhere");
  });
});

describe("the start's onboarding line", () => {
  const suggested: OnboardingSuggested = {
    seq: 2,
    workspace: "/home/ada/repo",
    due: "first",
    briefDue: "outdated",
    reasons: ["first", "brief"],
    proposals: { instructions: 2, rules: 2 },
    files: 4,
    onboardedVersion: undefined,
    onboardingVersion: 2,
    briefVersion: 1,
    surveyVersion: 2,
  };

  it("names the panel's answers while it asks, and no terminal command", () => {
    const line = onboardingNote(suggested, onboardAsk)!;
    expect(line).toBe(
      "Other tools' files are here: Onboard brings in 2 AGENTS.md files and 2 rules as Troupe's own files, and Review shows each as a diff first. Nothing is written until you choose. " +
        "The project brief was written by version 1 of the librarian's survey, and this build's is version 2.",
    );
    expect(line).not.toMatch(/`|troupe onboard|\/memory/);
  });

  it("names no answer once the panel asks something else, and the brief's Re-run while it asks that", () => {
    expect(onboardingNote(suggested, null)).toBe(
      "Other tools' files are here: onboarding would bring in 2 AGENTS.md files and 2 rules as Troupe's own files. " +
        "The project brief was written by version 1 of the librarian's survey, and this build's is version 2.",
    );
    expect(onboardingNote(suggested, { kind: "brief", text: "Rewrite?", detail: "" })).toContain("this build's is version 2: Re-run has the librarian write it again.");
  });

  it("says the re-run of older rules", () => {
    const outdated = { ...suggested, reasons: ["outdated"], onboardedVersion: 1, due: "outdated" };
    expect(onboardingNote(outdated, { ...onboardAsk, due: "outdated" })).toBe(
      "This workspace was onboarded under version 1 of the onboarding rules, and this build's are version 2: Re-run shows what they would write now.",
    );
  });

  it("leaves the harness's sentence where the daemon sent nothing to word it from", () => {
    expect(onboardingNote({ ...suggested, reasons: [] }, onboardAsk)).toBeNull();
    expect(onboardingNote({ ...suggested, proposals: {}, files: undefined }, onboardAsk)).toBeNull();
  });
});
