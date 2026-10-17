// The organisation's document: its defaults, below each person's own settings, and its
// enforced set, above everything a person sets, both through `admin.settings.list` and
// `admin.setting.put`. The keys the enforced set may hold are the plane's list, not this
// console's: a key the plane adds is offered with nothing changed here.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { ENFORCEABLE } from "../../../packages/client/test/support/admin.js";
import { PEOPLE, button, field, freshBrowser, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
  visit("#/organisation");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const enforced = (): HTMLElement | null => document.querySelector<HTMLElement>(".enforced");
const row = (key: string): HTMLElement | null => document.querySelector<HTMLElement>(`.row[aria-label="${key}"]`);

describe("the organisation's document", () => {
  it("shows the defaults with where each came from, and the enforced set against the keys the plane lists", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => enforced(), "the enforced set");

    await sees("openai", () => row("client_provider"));
    await sees("deployed", () => row("client_provider"));
    await sees("glm-5.2", () => row("client_model_default"));
    await sees("set here", () => row("client_model_default"));
    await sees("unset", () => row("client_model_expensive"));

    const keys = [...enforced()!.querySelectorAll("tbody tr td:first-child")].map((td) => td.textContent);
    expect(keys).toEqual(ENFORCEABLE.map((k) => k.key));
    await sees("200", () => enforced());
    await sees("the most it may be", () => enforced());
  });

  it("offers a key the plane lists that this console has never heard of", async () => {
    fake.admin.enforceable = [...ENFORCEABLE, { key: "max_cost_micros", kind: "ceiling", meaning: "the most it may be", type: "integer", min: 0 }];
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => enforced() && says("max_cost_micros", enforced()!), "the plane's new key");

    button("Change the enforced set")!.click();
    type(await waitFor(() => field("max_cost_micros", enforced()!), "its field"), "5000000");
    button("Preview", enforced()!)!.click();
    (await waitFor(() => button("Apply", enforced()!), "the preview")).click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_enforced"), "the audit's note");
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200, max_cost_micros: 5_000_000 });
  });

  it("previews a lower ceiling in words, applies it on confirm, and shows the audit's diff", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the enforced set"), "the enforced set")).click();
    type(await waitFor(() => field("max_turns", enforced()!), "the form"), "50");
    type(field("approvals", enforced()!)!, "deny");
    button("Preview", enforced()!)!.click();

    await waitFor(() => says("What will happen", enforced()!), "the preview");
    await sees("No machine may set max_turns above 50; a lower value stays.", () => enforced());
    await sees("No machine may loosen approvals past deny; a tighter value stays.", () => enforced());
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200 });

    button("Apply", enforced()!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_enforced"), "the audit's note");
    await sees("client_enforced.max_turns");
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "deny", max_turns: 50 });
    expect(fake.admin.audit.at(-1)!.detail).toEqual({
      "client_enforced.approvals": { from: "wait", to: "deny" },
      "client_enforced.max_turns": { from: 200, to: 50 },
    });
  });

  it("changes a default and resets one, each previewed and recorded", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const cheap = await waitFor(() => row("client_model_cheap"), "the defaults");
    button("Change", cheap)!.click();
    type(await waitFor(() => field("client_model_cheap", cheap), "the field"), "qwen3.6-35b");
    button("Preview", cheap)!.click();
    await waitFor(() => says("A person's own settings file still wins over a default.", cheap), "the preview");
    button("Apply", cheap)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_model_cheap"), "the audit's note");
    expect(fake.admin.stored.get("client_model_cheap")).toBe("qwen3.6-35b");

    const model = await waitFor(() => row("client_model_default") && button("Reset", row("client_model_default")!) && row("client_model_default"), "the stored default");
    button("Reset", model!)!.click();
    await waitFor(() => says("It goes back to what the plane was deployed with.", row("client_model_default")!), "the reset's preview");
    button("Reset", row("client_model_default")!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.reset on client_model_default"), "the reset's note");
    expect(fake.admin.stored.has("client_model_default")).toBe(false);
  });

  it("shows a plane's refusal of the set where it was made", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the enforced set"), "the enforced set")).click();
    type(await waitFor(() => field("max_depth", enforced()!), "the form"), "lots");
    button("Preview", enforced()!)!.click();
    (await waitFor(() => button("Apply", enforced()!), "the preview")).click();
    await waitFor(() => says("max_depth must be a whole number", enforced()!), "the refusal");
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200 });
  });

  it("lets a team admin read the document and change none of it", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => enforced(), "the enforced set");
    expect(button("Change the enforced set")).toBeNull();
    expect(button("Change", row("client_provider")!)).toBeNull();
    await sees("Only a platform admin changes the organisation's document.");
  });

  it("keeps the enforced rules when another key of the set is changed", async () => {
    const permissions = { deny: ["shell(git push)"] };
    fake.admin.stored.set("client_enforced", { approvals: "wait", max_turns: 200, permissions });
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the enforced set"), "the enforced set")).click();
    // The rules have their own editor: no field here holds them as text.
    expect(field("permissions", enforced()!)).toBeNull();
    type(await waitFor(() => field("max_turns", enforced()!), "the form"), "100");
    button("Preview", enforced()!)!.click();
    (await waitFor(() => button("Apply", enforced()!), "the preview")).click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_enforced"), "the audit's note");
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 100, permissions });
  });

  it("shows the set as stored on a plane that does not list its keys", async () => {
    fake.admin.enforceable = null;
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("This plane does not list the keys it may enforce"), "the older plane's set");
    await sees('"max_turns": 200');
    expect(button("Change the enforced set")).toBeNull();
  });
});

describe("the organisation's permission rules", () => {
  const rules = (): HTMLElement | null => document.querySelector<HTMLElement>('section[aria-label="Permission rules"]');
  const ruleRow = (action: string, n: number): HTMLElement => rules()!.querySelector<HTMLElement>(`[aria-label="${action} rule ${n}"]`)!;
  const stored = { deny: ["shell(git push)", "read_file(secrets/**)"], ask: ["mcp(github.create_*)"] };

  beforeEach(() => {
    fake.admin.stored.set("client_enforced", { approvals: "wait", max_turns: 200, permissions: stored });
  });

  it("reads each action's rules, and the set's table counts them", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => rules(), "the rules");
    await sees("2 deny, 1 ask (below)", () => enforced());
    const deny = rules()!.querySelector<HTMLElement>('[aria-label="deny rules"]')!;
    expect([...deny.querySelectorAll("li code")].map((c) => c.textContent)).toEqual(["shell(git push)", "read_file(secrets/**)"]);
    await sees("none", () => rules()?.querySelector<HTMLElement>('[aria-label="allow rules"]'));
  });

  it("adds, edits and removes rules as a tool and a pattern, previews them in words, and records the change", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the rules"), "the rules")).click();
    await waitFor(() => ruleRow("deny", 1), "the rules' form");
    expect(field("Tool", ruleRow("deny", 1))!.value).toBe("shell");
    expect(field("Pattern", ruleRow("deny", 1))!.value).toBe("git push");

    // Edited: the push rule now reaches only a forced push.
    type(field("Pattern", ruleRow("deny", 1))!, "git   push  --force");
    await waitFor(() => says("The plane reads it as shell(git push --force).", ruleRow("deny", 1)), "the rule as the plane reads it");
    // Removed: the secrets rule.
    button("Remove", ruleRow("deny", 2))!.click();
    // Added: an allow rule.
    button("Add an allow rule", rules()!)!.click();
    type(await waitFor(() => ruleRow("allow", 1) && field("Tool", ruleRow("allow", 1)), "the new row"), "shell");
    type(field("Pattern", ruleRow("allow", 1))!, "mix test");

    button("Preview", rules()!)!.click();
    await waitFor(() => says("What will happen", rules()!), "the preview");
    await sees("Every machine refuses shell(git push --force), whatever its own files allow.", () => rules());
    await sees("shell(git push) is no longer refused by the organisation", () => rules());
    await sees("read_file(secrets/**) is no longer refused by the organisation", () => rules());
    await sees("Every machine may run shell(mix test) unasked", () => rules());
    // The ask list did not move, so it is not in the diff.
    expect(says("permissions.ask", rules()!)).toBe(false);
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200, permissions: stored });

    button("Apply", rules()!)!.click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_enforced"), "the audit's note");
    expect(fake.admin.stored.get("client_enforced")).toEqual({
      approvals: "wait",
      max_turns: 200,
      permissions: { deny: ["shell(git push --force)"], ask: ["mcp(github.create_*)"], allow: ["shell(mix test)"] },
    });
    // Only the rules moved: the audit's diff names nothing else of the set.
    expect(Object.keys(fake.admin.audit.at(-1)!.detail ?? {}).sort()).toEqual(["client_enforced.permissions.allow", "client_enforced.permissions.deny"]);
    await waitFor(() => rules() && says("shell(mix test)", rules()!.querySelector<HTMLElement>('[aria-label="allow rules"]')!), "the rules read again");
  });

  it("refuses a malformed rule at its field, in the plane's own words, before anything is sent", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the rules"), "the rules")).click();
    await waitFor(() => ruleRow("ask", 1), "the rules' form");

    type(field("Tool", ruleRow("ask", 1))!, "Bash");
    await waitFor(() => says("Bash is another tool's name for it; Troupe's is shell, as in shell(...)", ruleRow("ask", 1)), "the tool refused");
    expect(button("Preview", rules()!)!.disabled).toBe(true);

    type(field("Tool", ruleRow("ask", 1))!, "shell");
    type(field("Pattern", ruleRow("ask", 1))!, "npm test:*");
    await waitFor(() => says("drop the :*, since shell(npm test) already matches every command that starts with it", ruleRow("ask", 1)), "the pattern refused");
    expect(button("Preview", rules()!)!.disabled).toBe(true);

    type(field("Tool", ruleRow("ask", 1))!, "web_fetch");
    type(field("Pattern", ruleRow("ask", 1))!, "example.com");
    await waitFor(() => says("web_fetch takes no pattern", ruleRow("ask", 1)), "a pattern on a tool that takes none");
    await sees("web_fetch takes no pattern: leave this empty.", ruleRow("ask", 1));

    type(field("Pattern", ruleRow("ask", 1))!, "");
    await waitFor(() => !button("Preview", rules()!)!.disabled, "the rule fixed");
    expect(fake.admin.audit.filter((a) => a.subject_id === "client_enforced")).toEqual([]);
  });

  it("takes every rule away, leaving the set without any", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change the rules"), "the rules")).click();
    await waitFor(() => ruleRow("ask", 1), "the rules' form");
    for (const [action, n] of [["deny", 2], ["deny", 1], ["ask", 1]] as const) button("Remove", ruleRow(action, n))!.click();
    (await waitFor(() => !button("Preview", rules()!)!.disabled && button("Preview", rules()!), "every row gone")).click();
    (await waitFor(() => button("Apply", rules()!), "the preview")).click();
    await waitFor(() => says("Recorded in the audit as setting.put on client_enforced"), "the audit's note");
    expect(fake.admin.stored.get("client_enforced")).toEqual({ approvals: "wait", max_turns: 200 });
    await waitFor(() => says("The organisation enforces no rule", rules()!), "no rule");
  });

  it("lets a team admin read the rules and change none", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => rules() && says("shell(git push)", rules()!), "the rules");
    expect(button("Change the rules")).toBeNull();
  });
});
