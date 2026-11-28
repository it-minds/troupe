// troupe #1239 in the console: a sensitive session's mark on Your sessions and on every
// session's row, its owner's Make it sensitive (asked once more, since nothing clears it),
// the waiting sentence where its profile holds a share for a team administrator, the
// administrator's queue on the team's page with Allow and Refuse, and the profile editor's
// three fields (`sensitive.markedBy`, `sensitive.deny`, `sensitive.sharing`) beside #1234's
// `github.maxRepositories` and `github.maxAttempts`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { draftOf, keptOf, sensitiveProblem } from "../src/views/Profiles";
import { PEOPLE, button, field, freshBrowser, opener, render, says, sees, seesButton, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

const BY_CALL = { at: "2026-11-28T10:14:00Z", by: "mcp.records.lookup", how: "call" as const };

async function deployment(plane: Parameters<typeof startFake>[1] = {}): Promise<void> {
  fake = await startFake(exampleAdmin(), { memberOf: { [PEOPLE.carol.subject]: ["design"] }, teamAdmins: [PEOPLE.bob.subject], ...plane });
}

beforeEach(() => {
  freshBrowser();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  close();
  await fake.stop();
});

const { open, close } = opener(() => fake);
const yours = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="Your sessions"]');
const rowOf = (text: string): HTMLTableRowElement | undefined => [...(yours()?.querySelectorAll<HTMLTableRowElement>("tbody tr") ?? [])].find((r) => r.textContent?.includes(text));

describe("Your sessions", () => {
  it("marks a sensitive one with since when and by what, and lets its owner make another so, asked once more", async () => {
    await deployment();
    fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-9", title: "Ann's record", profile: "ux", sensitive: BY_CALL });
    const plain = fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-8", title: "Plain", profile: "ux" });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/sessions");
    unmount = render(<App />).unmount;

    await sees("Sensitive", yours);
    const mark = await waitFor(() => [...(rowOf("Ann's record")?.querySelectorAll<HTMLElement>("span[title]") ?? [])].find((s) => s.textContent === "sensitive"), "the mark");
    expect(mark.title).toMatch(/^Sensitive since \d\d:\d\d: mcp\.records\.lookup read from it; nothing clears it$/);

    (await seesButton("Make it sensitive", rowOf("Plain")!)).click();
    await sees("Nothing clears it", () => rowOf("Plain")!);
    expect(plain.sensitive).toBeNull();
    button("Cancel", rowOf("Plain")!)!.click();
    await waitFor(() => !rowOf("Plain")!.querySelector('[aria-label="Make it sensitive?"]'), "the question gone");
    (await seesButton("Make it sensitive", rowOf("Plain")!)).click();
    const ask = await waitFor(() => rowOf("Plain")!.querySelector<HTMLElement>('[aria-label="Make it sensitive?"]'), "the question");
    button("Make it sensitive", ask)!.click();
    await waitFor(() => plain.sensitive?.how === "person", "the plane told");
    await waitFor(() => [...rowOf("Plain")!.querySelectorAll("span[title]")].some((s) => s.textContent === "sensitive" && (s as HTMLElement).title.includes("marked by you")), "the mark");
    expect(button("Make it sensitive", rowOf("Plain")!)).toBeNull();
  });

  it("says a share waits on a team administrator where the profile asks, and nothing changes", async () => {
    await deployment({ sensitiveSharing: "ask" });
    const record = fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-9", title: "Ann's record", profile: "ux", visibility: "private", sensitive: BY_CALL });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/sessions");
    unmount = render(<App />).unmount;
    (await seesButton("Give it to the design team", rowOf("Ann's record")!)).click();
    await sees("waiting on a team administrator", () => rowOf("Ann's record")!);
    await sees("(it waits)", () => rowOf("Ann's record")!);
    expect(record.visibility).toBe("private");
    expect(fake.plane.shareRequests).toHaveLength(1);
  });

  it("says the profile's refusal where it denies", async () => {
    await deployment({ sensitiveSharing: "deny" });
    fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-9", title: "Ann's record", profile: "ux", visibility: "private", sensitive: BY_CALL });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/sessions");
    unmount = render(<App />).unmount;
    (await seesButton("Give it to the design team", rowOf("Ann's record")!)).click();
    await sees("This session is sensitive and ux does not allow sharing it outside the people who already read it.", () => rowOf("Ann's record")!);
  });

  it("offers no Make it sensitive where the plane does not know sensitive sessions", async () => {
    await deployment({ beforeSensitive: true });
    fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-8", title: "Plain", profile: "ux" });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/sessions");
    unmount = render(<App />).unmount;
    await waitFor(() => rowOf("Plain"), "the row");
    expect(button("Make it sensitive", rowOf("Plain")!)).toBeNull();
    expect(says("Sensitive", yours()!)).toBe(false);
  });
});

describe("every session", () => {
  it("marks a sensitive session's row, and says no for one that is not", async () => {
    await deployment();
    fake.admin.sessions.find((s) => s.id === "s-7f3a9c21")!.sensitive = BY_CALL;
    await open("#/sessions");
    const rows = (): HTMLTableRowElement[] => [...document.querySelectorAll<HTMLTableRowElement>("table.sessions tbody tr")];
    const marked = await waitFor(() => rows().find((r) => r.textContent?.includes("s-7f3a9c21")), "the row");
    const mark = await waitFor(() => [...marked.querySelectorAll<HTMLElement>("span[title]")].find((s) => s.textContent === "sensitive"), "the mark");
    expect(mark.title).toContain("mcp.records.lookup read from it");
    expect(says("Sensitive", document.querySelector("table.sessions thead")!)).toBe(true);
  });
});

describe("the share requests waiting on a team administrator", () => {
  async function held(): Promise<void> {
    await deployment({ sensitiveSharing: "ask" });
    fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-9", title: "Ann's record", profile: "ux", visibility: "private", sensitive: BY_CALL });
    fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-7", title: "Bea's record", profile: "ux", visibility: "private", sensitive: BY_CALL });
    const carol = await fake.plane.rpcAs(PEOPLE.carol.subject, "session.visibility.set", { session_id: "s-carol-9", visibility: "team" });
    expect(carol).toMatchObject({ result: { waiting: true } });
    fake.plane.people = [{ subject: PEOPLE.alice.subject, display_name: PEOPLE.alice.name, email: PEOPLE.alice.subject }];
    const invited = await fake.plane.rpcAs(PEOPLE.carol.subject, "session.invite", { session_id: "s-carol-7", subject: PEOPLE.alice.subject, role: "observe" });
    expect(invited).toMatchObject({ result: { waiting: true } });
  }

  it("are on the team's page, each allowed or refused, the yes applied as the owner asked", async () => {
    await held();
    await open("#/teams/design/shares", PEOPLE.bob);
    const list = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Waiting shares"]'), "the waiting shares");
    await sees("asks to give it to design", list);
    await sees("s-carol-9", list);
    // Read again after each answer, so each lookup is of the list as it is now.
    const item = (id: string) => [...document.querySelectorAll('[aria-label="Waiting shares"] li')].find((li) => li.textContent?.includes(id)) ?? null;
    button("Allow", item("s-carol-9")!)!.click();
    await waitFor(() => fake.plane.rows.get("s-carol-9")?.visibility === "team", "the share applied");
    await waitFor(() => !item("s-carol-9") && item("s-carol-7"), "the request answered");
    (await seesButton("Refuse", item("s-carol-7")!)).click();
    await waitFor(() => fake.plane.shareRequests.find((r) => r.session_id === "s-carol-7")?.state === "declined", "refused");
    await sees("Nothing waits on you");
    expect(fake.plane.invitations.get("s-carol-7")?.get(PEOPLE.alice.subject)).toBeUndefined();
  });

  it("is empty for an administrator of another team", async () => {
    await held();
    await open("#/teams/core/shares");
    await sees("Nothing waits on you");
  });
});

describe("the profile editor", () => {
  it("maps the sensitive lists and sharing, and the GitHub caps, onto the spec", () => {
    const form = {
      name: "records",
      extends: "",
      image: "registry.example.com/troupe/worker:1",
      sizeClass: "standard",
      maxSessions: "",
      budget: "",
      warmWorkers: "0",
      endpoint: "",
      provider: "",
      model: "",
      smallModel: "",
      maxTokens: "",
      secretName: "",
      secretKey: "",
      fqdns: "",
      gitHosts: "",
      storageClass: "",
      channel: "",
      orgMount: false,
      repositoryOverridesBundle: false,
      forbidPersonalTools: false,
      memoryProposals: true,
      allowPublic: false,
      denyPaths: "",
      maxPushes: "",
      maxRuns: "",
      maxRepositories: "5",
      maxAttempts: "2",
      sharing: "ask",
    };
    const spec = draftOf(form, [], keptOf({}), undefined, { markedBy: ["mcp(records.*)"], deny: ["publish_artifact", "web_fetch"] }).spec!;
    expect(spec["sensitive"]).toEqual({ markedBy: ["mcp(records.*)"], deny: ["publish_artifact", "web_fetch"], sharing: "ask" });
    expect(spec["github"]).toEqual({ maxRepositories: 5, maxAttempts: 2 });
    expect("sensitive" in draftOf({ ...form, sharing: "" }, [], keptOf({})).spec!).toBe(false);
    expect(sensitiveProblem({ markedBy: ["mcp(records.*)"], deny: [] })).toContain("Say which tools a sensitive session is refused");
    expect(sensitiveProblem({ markedBy: [], deny: [] })).toBeNull();
  });

  it("reads them on the profile, the GitHub caps' defaults where it says none", async () => {
    await deployment();
    await open("#/profiles/dev");
    await sees("Sensitive sessions");
    await sees("None: no call marks a session here sensitive");
    await sees("Repositories a session may hold");
    await sees("Runs on one issue before it is left for a person");
    await sees("1, Troupe's default, or a team's lower cap");
  });

  it("edits them behind the plane's preview, refusing rules that mark with nothing refused, and reads them back", async () => {
    await deployment();
    await open("#/profiles/dev");
    (await waitFor(() => button("Change dev"), "dev")).click();
    await waitFor(() => field("Sharing a sensitive session"), "the editor");
    const fieldset = (legend: string) => [...document.querySelectorAll<HTMLFieldSetElement>("fieldset.rule-action")].find((f) => f.querySelector("legend")?.textContent?.startsWith(legend))!;
    button("Add a markedBy rule", fieldset("Marks it sensitive"))!.click();
    const marked = await waitFor(() => fieldset("Marks it sensitive").querySelector<HTMLElement>(".rule-row"), "the row");
    type(marked.querySelector<HTMLInputElement>("input")!, "mcp");
    type(marked.querySelectorAll<HTMLInputElement>("input")[1]!, "records.*");
    await sees("Say which tools a sensitive session is refused");
    expect(button("Preview")!.disabled).toBe(true);
    button("Add a deny rule", fieldset("Refused once sensitive"))!.click();
    const denied = await waitFor(() => fieldset("Refused once sensitive").querySelector<HTMLElement>(".rule-row"), "the deny row");
    type(denied.querySelector<HTMLInputElement>("input")!, "publish_artifact");
    type(field("Sharing a sensitive session")!, "deny");
    type(field("Repositories a session may hold")!, "4");
    type(field("Runs on one issue before it is left for a person")!, "2");
    await waitFor(() => !button("Preview")!.disabled, "Preview, ready");
    button("Preview")!.click();
    await waitFor(() => says("What will happen"), "the preview");
    await sees('spec.sensitive: {"markedBy":["mcp(records.*)"],"deny":["publish_artifact"],"sharing":"deny"}');
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on dev"), "the audit's note");
    const spec = fake.admin.profiles.find((p) => p.name === "dev")!.spec!;
    expect(spec["sensitive"]).toEqual({ markedBy: ["mcp(records.*)"], deny: ["publish_artifact"], sharing: "deny" });
    expect(spec["github"]).toMatchObject({ maxRepositories: 4, maxAttempts: 2 });
    await waitFor(() => says("refused: only those who read it now"), "dev read again");
    await sees("mcp(records.*)");
  });
});
