// Integrations: the GitHub App, read, tested against GitHub, set and removed, and what the
// plane dials, against the fake plane's `admin.github.get`, `.put`, `.check` and `.delete`
// and `admin.integrations.list`, with the plane's two roles.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
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
    await sees("4242", card());
    await sees("example-org (77001)", card());
    await sees("https://github.com", card());
    await sees(fake.admin.github.key!.fingerprint, card());
    await sees("never shown", card());
  });

  it("is tested against GitHub, writing nothing, and says which check failed", async () => {
    await open();
    (await waitFor(() => button("Test it"), "the App")).click();
    await waitFor(() => says("GitHub knows the App as troupe-example, and every installation set here."), "GitHub's answer");
    await sees("Installations");
    expect(fake.admin.audit.some((a) => a.action.startsWith("github."))).toBe(false);

    // GitHub holds another key for the App: the plane signs, and GitHub refuses it.
    fake.admin.githubKnows!.fingerprint = "SHA256:another";
    button("Test it")!.click();
    await waitFor(() => says("GitHub refused the App's JWT"), "the refusal");
    await sees("Not tried: GitHub did not pass.");
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
    await sees("The key becomes the next version in OpenBao");
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

  it("takes a webhook secret once, never shows it back, and lists what GitHub has sent", async () => {
    await open();
    await waitFor(() => says("signed with a secret at version 1"), "the webhook");
    await waitFor(() => says("pull_request_review.submitted") && says("s-7f3a9c24"), "the deliveries");
    await sees("nothing here acts on a push");

    button("Change the App")!.click();
    type(await waitFor(() => field("Webhook secret"), "the form"), "0123456789abcdef0123456789abcdef");
    button("Preview")!.click();
    await waitFor(() => says("GitHub's webhook settings must have the same one"), "the preview");
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as github.put on app") && says("signed with a secret at version 2"), "the audit's note");
    expect(says("0123456789abcdef0123456789abcdef")).toBe(false);
    expect(JSON.stringify(fake.admin.audit)).not.toContain("0123456789abcdef0123456789abcdef");
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
    await sees("A session that names a repository is refused from now on");
    const go = () => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith("Remove the App"))!;
    expect(go().disabled).toBe(true);
    type(field("Type 4242 to confirm")!, "4242");
    await waitFor(() => !go().disabled, "the id typed");
    go().click();
    await waitFor(() => says("Recorded in the audit as github.delete on app") && says("not configured"), "the App removed");
    expect(fake.admin.github.app_id).toBeNull();
    expect(fake.admin.github.key).toBeNull();
  });

  // #653: on a gitops plane a `GitHubApp` resource holds the App's settings; its key and its
  // webhook secret are no resource's, and are still set here.
  it("is shown locked on a gitops plane, where only its key and webhook secret are set here", async () => {
    fake.admin.mode = "gitops";
    fake.admin.gitopsSource = "https://git.example.com/platform/troupe.git";
    await open();
    await waitFor(() => says("Held in a repository", card()) && says("GitHubApp/github", card()), "the locked App");
    await sees("https://git.example.com/platform/troupe.git", card());
    await sees("read at generation 1", card());
    expect(button("Remove the App")).toBeNull();
    expect(button("Change the App")).toBeNull();

    (await waitFor(() => button("Set its key or webhook secret"), "the key's button")).click();
    await waitFor(() => field("Private key"), "the form");
    expect(field("App ID")).toBeNull();
    expect(field("Installations")).toBeNull();
    type(field("Private key")!, PEM);
    button("Preview")!.click();
    (await waitFor(() => button("Apply"), "the preview")).click();
    await waitFor(() => says("Recorded in the audit as github.put on app"), "the audit's note");
    expect(fake.admin.github.key!.version).toBe(2);
    expect(fake.admin.github.app_id).toBe(4242);
  });

  it("is read by a team admin, who is offered nothing to change or test", async () => {
    await open(PEOPLE.bob);
    await waitFor(() => says("The GitHub App") && says("4242"), "the App");
    expect(button("Test it")).toBeNull();
    expect(button("Change the App")).toBeNull();
    expect(button("Remove the App")).toBeNull();
    await sees("Only a platform admin changes or tests the App");
    expect(says("What GitHub has sent")).toBe(false);
  });
});

describe("what the plane dials", () => {
  it("lists the servers, every host against the policy with where it was declared, and each outcome's target", async () => {
    fake.admin.profiles.find((p) => p.name === "ux")!.spec!["egress"] = { fqdns: ["mcp.example.com", "elsewhere.example.org"] };
    await open();
    await waitFor(() => says("Every host anything here dials"), "the hosts");
    const hostRow = (host: string) => [...document.querySelectorAll("tr")].find((r) => r.cells[0]?.textContent === host) ?? null;
    await sees("allowed", () => hostRow("llm-gw.example.com"));
    await sees("refused", () => hostRow("elsewhere.example.org"));
    await sees("ux", () => hostRow("elsewhere.example.org"));
    await sees("a Secret named JIRA_TOKEN");
    await sees("design/weekly-digest");
    await sees("https://hooks.example.com/troupe");
  });
});
