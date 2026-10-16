// Integrations: the GitHub App, read, tested against GitHub, set and removed, and what the
// plane dials, against the fake plane's `admin.github.get`, `.put`, `.check` and `.delete`
// and `admin.integrations.list`, with the plane's two roles.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
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

async function open(who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit("#/integrations");
  unmount = render(<App />).unmount;
}

const card = (): HTMLElement => document.querySelector<HTMLElement>('[aria-label="The GitHub App"]')!;
const PEM = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAexampleexampleexample\n-----END RSA PRIVATE KEY-----\n";

describe("the GitHub App", () => {
  it("reads what is set, the key by its fingerprint and never the key", async () => {
    await open();
    await waitFor(() => says("The GitHub App") && says("configured"), "the App");
    expect(says("4242", card())).toBe(true);
    expect(says("example-org (77001)", card())).toBe(true);
    expect(says("https://github.com", card())).toBe(true);
    expect(says(fake.admin.github.key!.fingerprint, card())).toBe(true);
    expect(says("never shown", card())).toBe(true);
  });

  it("is tested against GitHub, writing nothing, and says which check failed", async () => {
    await open();
    (await waitFor(() => button("Test it"), "the App")).click();
    await waitFor(() => says("GitHub knows the App as troupe-example, and every installation set here."), "GitHub's answer");
    expect(says("Installations")).toBe(true);
    expect(fake.admin.audit.some((a) => a.action.startsWith("github."))).toBe(false);

    // GitHub holds another key for the App: the plane signs, and GitHub refuses it.
    fake.admin.githubKnows!.fingerprint = "SHA256:another";
    button("Test it")!.click();
    await waitFor(() => says("GitHub refused the App's JWT"), "the refusal");
    expect(says("Not tried: GitHub did not pass.")).toBe(true);
  });

  it("is changed behind a preview, the key pasted once and kept nowhere, and shown as the audit recorded it", async () => {
    await open();
    (await waitFor(() => button("Change the App"), "the App")).click();
    const installations = await waitFor(() => field("Installations"), "the form");
    expect(installations.value).toBe("example-org 77001");
    type(installations, "example-org 77001\nother-org 9");
    type(field("Private key")!, PEM);
    button("Preview")!.click();
    await waitFor(() => says("What will happen") && says("Sessions may name repositories of example-org, other-org."), "the preview");
    expect(says("The key becomes the next version in OpenBao")).toBe(true);
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as github.put on app"), "the audit's note");
    expect(fake.admin.github.installations).toEqual([
      { owner: "example-org", installation_id: 77001 },
      { owner: "other-org", installation_id: 9 },
    ]);
    expect(fake.admin.github.key!.version).toBe(2);
    // The PEM is in no answer and no record: the page holds the fingerprint, the audit too.
    await waitFor(() => !says("BEGIN RSA PRIVATE KEY"), "the form gone");
    expect(JSON.stringify(fake.admin.audit)).not.toContain("BEGIN RSA PRIVATE KEY");
  });

  it("shows the plane's refusal where the change was asked for", async () => {
    await open();
    (await waitFor(() => button("Change the App"), "the App")).click();
    type(await waitFor(() => field("Installations"), "the form"), "-bad- 1");
    button("Preview")!.click();
    (await waitFor(() => button("Apply"), "the preview")).click();
    await waitFor(() => says('"-bad-" is not an organisation or account name'), "the refusal");
    expect(fake.admin.github.installations).toEqual([{ owner: "example-org", installation_id: 77001 }]);
  });

  it("is removed only once its App ID is typed", async () => {
    await open();
    (await waitFor(() => button("Remove the App"), "the App")).click();
    await waitFor(() => says("Type 4242 to confirm"), "the typed confirmation");
    expect(says("A session that names a repository is refused from now on")).toBe(true);
    const go = () => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith("Remove the App"))!;
    expect(go().disabled).toBe(true);
    type(field("Type 4242 to confirm")!, "4242");
    await waitFor(() => !go().disabled, "the id typed");
    go().click();
    await waitFor(() => says("Recorded in the audit as github.delete on app") && says("not configured"), "the App removed");
    expect(fake.admin.github.app_id).toBeNull();
    expect(fake.admin.github.key).toBeNull();
  });

  it("is read by a team admin, who is offered nothing to change or test", async () => {
    await open(PEOPLE.bob);
    await waitFor(() => says("The GitHub App") && says("4242"), "the App");
    expect(button("Test it")).toBeNull();
    expect(button("Change the App")).toBeNull();
    expect(button("Remove the App")).toBeNull();
    expect(says("Only a platform admin changes or tests the App")).toBe(true);
  });
});

describe("what the plane dials", () => {
  it("lists the servers, every host against the policy with where it was declared, and each outcome's target", async () => {
    fake.admin.profiles.find((p) => p.name === "ux")!.spec!["egress"] = { fqdns: ["mcp.example.com", "elsewhere.example.org"] };
    await open();
    await waitFor(() => says("Every host anything here dials"), "the hosts");
    const hostRow = (host: string) => [...document.querySelectorAll("tr")].find((r) => r.cells[0]?.textContent === host) ?? null;
    expect(says("allowed", hostRow("llm-gw.example.com")!)).toBe(true);
    expect(says("refused", hostRow("elsewhere.example.org")!)).toBe(true);
    expect(says("ux", hostRow("elsewhere.example.org")!)).toBe(true);
    expect(says("a Secret named JIRA_TOKEN")).toBe(true);
    expect(says("design/weekly-digest")).toBe(true);
    expect(says("https://hooks.example.com/troupe")).toBe(true);
  });
});
