// What a member sees, on the administrator's page of a profile: the plane's `profile.get`
// asked as the administrator, answered for no team, drawn as tables and nothing to change.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { FUNCTIONS_HEADING } from "@troupe/client";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { exampleProfiles } from "../../../packages/client/test/support/profiles.js";
import { freshBrowser, opener, recordCalls, says, sees, startFake, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  close();
  await fake.stop();
});

const member = (): HTMLElement | null => document.querySelector<HTMLElement>(".member-view");

const { open, close } = opener(() => fake);

describe("what a member sees", () => {
  it("is the plane's answer for a member's app, in tables, with whose access each server is called", async () => {
    const { calls, restore } = recordCalls();
    try {
      await open("#/profiles/dev");
      await sees("What a member sees");
      await sees("as you, once you connect it", member);
      await sees("as the profile's own identity", member);
      await sees("search_issues, get_issue", member);
      await sees("git push *", member);
      await sees("the profile", member);
      await sees("glm-5.2", member);
      await sees("profile $200.00", member);
      await sees("What the harness may run here", member);
      await sees("Answers an AI? question about the code", member);
      expect(member()!.querySelectorAll("input, select, textarea, button")).toHaveLength(0);
      expect(calls.filter((c) => c.method === "profile.get")).toHaveLength(1);
    } finally {
      restore();
    }
  });

  it("is answered for no team, so only the profile's own rule leaves an agent out", async () => {
    await open("#/profiles/ux");
    await sees("not here: the profile does not have it", member);
    // The librarian the profile's rule denies is a row not here, not among the harness's jobs.
    const caption = [...member()!.querySelectorAll("caption")].find((c) => c.textContent === "What the harness may run here");
    expect(caption?.closest("table")?.textContent).not.toContain("librarian");
    // The core team's grant leaves out plan; asked as the administrator, no grant narrows it.
    expect(says("your team's grant leaves it out")).toBe(false);
  });

  it("reads a profile the examples do not know from its spec", async () => {
    await open("#/profiles/heavy");
    await waitFor(() => member() && says("2 per pod"), "heavy's member view");
    await sees("no host outside its pod", member);
  });
});

/** The table under `caption` in the member view, as its rows' words. */
function rows(caption: string): string[][] | null {
  const found = [...member()!.querySelectorAll("caption")].find((c) => c.textContent === caption);
  const table = found?.closest("table");
  if (!table) return null;
  return [...table.querySelectorAll("tbody tr")].map((tr) => [...tr.querySelectorAll("th, td")].map((c) => (c.textContent ?? "").trim()));
}

/** Wait for the table under `caption` in the member view, and its rows' words. */
const table = (caption: string): Promise<string[][]> => waitFor(() => (member() ? rows(caption) : null), `the member view's ${caption} table`);

describe("what a member sees of the limits", () => {
  it("lists each limit with its value and whose number it is, Troupe's own where the profile sets none", async () => {
    await open("#/profiles/dev");
    const limits = await table("Limits");
    expect(limits).toEqual([
      ["Output of one model call", "at most 8,192 tokens", "Troupe's default"],
      ["Working time before an agent asks to go on", "30 minutes; waiting on a person does not count", "Troupe's default"],
      ["Model calls before an agent asks to go on", "40 model calls", "Troupe's default"],
      ["Input tokens before an agent asks to go on", "2,000,000 tokens", "Troupe's default"],
      ["Output tokens before an agent asks to go on", "400,000 tokens", "Troupe's default"],
      ["Delegation", "at most 3 levels deep", "Troupe's default"],
      // Asked as the administrator, for no team: the rest before a session sleeps is the platform's.
      ["Rest before a session sleeps", "30 minutes", "the platform"],
    ]);
  });

  it("says the profile's own output cap and an agent's own numbers beside it", async () => {
    const specs = exampleProfiles();
    const dev = specs.find((s) => s.name === "dev")!;
    dev.llm = { ...dev.llm, maxTokens: 4096 };
    dev.bundle.agents = [{ ...dev.bundle.agents[0]!, max_tokens: 2048 }];
    await fake.stop();
    fake = await startFake(exampleAdmin(), { profileSpecs: specs });
    await open("#/profiles/dev");
    const limits = await table("Limits");
    expect(limits[0]).toEqual(["Output of one model call", "at most 4,096 tokens", "the profile"]);
    const agents = await table("Agents");
    expect(agents).toContainEqual(["reviewer Reads a diff and comments on it", "subagent", "the bundle", "yes", "at most 20 model calls · at most 2,048 tokens a call"]);
    expect(agents).toContainEqual(["build Does the work: reads, edits and runs", "primary", "built in", "yes", "the session's"]);
  });

  it("shows GitHub's permissions and caps, the harness's tools with the refused marked, and the two switches", async () => {
    await open("#/profiles/dev");
    expect(await table("GitHub")).toEqual([
      ["Permissions", "contents: write, pull_requests: write"],
      ["Pushes a run may make", "at most 20 pushes"],
      ["Runs on a repository at once", "no cap"],
      ["Runs on one issue before a person is asked", "1 run"],
    ]);
    // dev's rules refuse no tool whole, so every tool of the harness is there.
    const tools = await table("The harness's tools");
    expect(tools).toContainEqual(["shell", "✓ yes"]);
    expect(tools.every((r) => r[1] === "✓ yes")).toBe(true);
    expect(await table("Switches")).toEqual([
      ["A person's own tools", "on: a person may offer a session here their own signed-in tools"],
      ["Memory proposals", "on: its agents may propose to a team's or the organisation's memory"],
    ]);
  });

  it("marks a tool a rule refuses whole with a mark and a word, and shows no GitHub table where the profile has none", async () => {
    const specs = exampleProfiles();
    const ux = specs.find((s) => s.name === "ux")!;
    ux.permissions = { deny: ["bash", "webfetch"] };
    ux.personalTools = "forbid";
    ux.memoryProposals = false;
    await fake.stop();
    fake = await startFake(exampleAdmin(), { profileSpecs: specs });
    await open("#/profiles/ux");
    const tools = await table("The harness's tools");
    expect(tools).toContainEqual(["shell", "✕ refused by a rule"]);
    expect(tools).toContainEqual(["web_fetch", "✕ refused by a rule"]);
    expect(tools).toContainEqual(["read_file", "✓ yes"]);
    const switches = await table("Switches");
    // at once: the view is drawn whole, so a table the answer gives no reason for is not coming.
    expect(rows("GitHub")).toBeNull();
    expect(switches).toEqual([
      ["A person's own tools", "off: a person may not offer a session here their own signed-in tools"],
      ["Memory proposals", "off: its agents may not propose to a team's or the organisation's memory"],
    ]);
  });

  it("says a plane's null rest for no team as not said, not as a number", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const answer = await original(input, init);
      if (typeof init?.body !== "string" || !init.body.includes('"profile.get"')) return answer;
      const body = (await answer.json()) as { result?: { limits: Record<string, unknown> } };
      if (body.result) body.result.limits["idle_seconds"] = null;
      return new Response(JSON.stringify(body), { status: answer.status, headers: { "content-type": "application/json" } });
    };
    try {
      await open("#/profiles/dev");
      const limits = await table("Limits");
      expect(limits.at(-1)).toEqual(["Rest before a session sleeps", "each team's own; asked for no team, so not said", "the platform"]);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("draws an older plane's answer, without them, as before", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const answer = await original(input, init);
      if (typeof init?.body !== "string" || !init.body.includes('"profile.get"')) return answer;
      const body = (await answer.json()) as {
        result?: Record<string, unknown> & {
          limits: Record<string, unknown>;
          agents: Array<Record<string, unknown>>;
        };
      };
      const r = body.result;
      if (r) {
        for (const k of ["harness_tools", "github", "personal_tools", "memory_proposals"]) delete r[k];
        for (const k of ["max_tokens", "session", "idle_seconds"]) delete r.limits[k];
        delete (r.limits["budgets"] as Record<string, unknown>)["team_period"];
        for (const a of r.agents) {
          delete a["max_turns"];
          delete a["max_tokens"];
        }
      }
      return new Response(JSON.stringify(body), {
        status: answer.status,
        headers: { "content-type": "application/json" },
      });
    };
    try {
      await open("#/profiles/dev");
      await sees("profile $200.00", member);
      const captions = [...member()!.querySelectorAll("caption")].map((c) => c.textContent);
      expect(captions).toEqual(["Agents", FUNCTIONS_HEADING, "Tool rules", "MCP servers", "Model, reach, limits and who"]);
      expect(rows("Agents")!.every((r) => r.length === 4)).toBe(true);
    } finally {
      globalThis.fetch = original;
    }
  });
});
