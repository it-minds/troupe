// Client versions: per component, the recommended version, the minimum and the blocked
// list, through `admin.clients.get` and `admin.clients.put`. A change is previewed, field
// by field and in words, before it is sent; the plane's refusal is shown where it was
// made, with nothing written; and what the audit recorded is shown once it is applied.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { PEOPLE, button, field, freshBrowser, render, says, sees, seesButton, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
  visit("#/clients");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const card = (name: string): HTMLElement | null => document.querySelector<HTMLElement>(`section.card[aria-label="${name}"]`);

describe("client versions", () => {
  it("shows each component's policy as the plane holds it", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    await sees("0.16.0-beta", terminal);
    await sees("0.14.0-beta", terminal);
    await sees("0.15.0-beta", terminal);
    await sees("last set by alice@example.com", terminal);
    await sees("never set", () => card("The daemon"));
    expect(card("The desktop app")).not.toBeNull();
  });

  it("previews a raised minimum, applies it on confirm, and shows what the audit recorded", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    button("Change", terminal)!.click();
    type(await waitFor(() => field("Minimum", terminal), "the form"), "0.16.0-beta");
    button("Preview", terminal)!.click();

    await waitFor(() => says("What will happen", terminal), "the preview");
    await sees("minimum: 0.14.0-beta", terminal);
    await sees("minimum: 0.16.0-beta", terminal);
    await sees("Every troupe older than 0.16.0-beta is refused when it next connects, and told to run troupe update.", terminal);
    // Nothing is sent until it is confirmed.
    expect(fake.admin.policies["tui"]!.minimum).toBe("0.14.0-beta");

    button("Apply", terminal)!.click();
    await waitFor(() => says("Recorded in the audit as clients.put on tui"), "the audit's note");
    expect(fake.admin.policies["tui"]!.minimum).toBe("0.16.0-beta");
    expect(fake.admin.audit.at(-1)).toMatchObject({ actor: "alice@example.com", action: "clients.put", subject_id: "tui", detail: { minimum: { from: "0.14.0-beta", to: "0.16.0-beta" } } });
    await sees("version policy is applied");
    await waitFor(() => !says("What will happen") && says("0.16.0-beta", card("The terminal")!), "the policy, as it now is");
  });

  it("shows the plane's refusal where it was made, and writes nothing", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    const recorded = fake.admin.audit.length;
    button("Change", terminal)!.click();
    type(await waitFor(() => field("Minimum", terminal), "the form"), "0.17.0-beta");
    button("Preview", terminal)!.click();
    (await waitFor(() => button("Apply", terminal), "the preview")).click();

    await waitFor(() => says("minimum: the minimum 0.17.0-beta is newer than the recommended version 0.16.0-beta", terminal), "the refusal");
    expect(fake.admin.policies["tui"]!.minimum).toBe("0.14.0-beta");
    expect(fake.admin.audit).toHaveLength(recorded);
  });

  it("says who last set a policy in their own letters, not the label's capitals", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    const who = terminal.querySelector<HTMLElement>(".meta .who");
    expect(who?.textContent).toBe("alice@example.com");
    // The label face is upper case; the person's address is shown as they have it.
    const css = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../src/styles.css"), "utf8");
    expect(css).toMatch(/\.meta \.who\s*\{[^}]*text-transform:\s*none/);
  });

  it("lets a team admin read the policy and change none of it", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    await sees("0.14.0-beta", terminal);
    expect(button("Change", terminal)).toBeNull();
    await sees("Only a platform admin changes these");
  });

  // #657: the clients each policy holds, as the plane last saw them connect.
  it("counts each component's clients against its policy, and lists who is behind and since when", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    await sees("4 clients last seen: 1 current, 1 behind the recommended version, 2 refused when they next connect.", terminal);
    await sees("1 client last seen: 1 current, 0 behind the recommended version.", () => card("The daemon"));
    await sees("None has connected since the plane began recording versions.", () => card("The desktop app"));

    const table = await waitFor(() => document.querySelector<HTMLTableElement>("table.behind"), "who is behind");
    const rows = [...table.querySelectorAll("tbody tr")].map((r) => [...r.querySelectorAll("td")].map((c) => c.textContent));
    // Oldest first: on the version they run longest.
    expect(rows.map((r) => r[0])).toEqual(["Fay (fay@example.com)", "Erin (erin@example.com)", "Dan (dan@example.com)"]);
    expect(rows[0]).toEqual(["Fay (fay@example.com)", "The terminal", "0.13.0-beta · windows/x86_64", "✕ refused when it next connects", "2026-09-30 16:20 UTC", "2026-10-13 08:55 UTC"]);
    expect(rows[1]![3]).toBe("◐ behind");

    type(document.querySelector<HTMLInputElement>('input[aria-label="Filter who is behind"]')!, "erin");
    await waitFor(() => table.querySelectorAll("tbody tr").length === 1, "the filtered list");
    await sees("0.14.2-beta", table);
    type(document.querySelector<HTMLInputElement>('input[aria-label="Filter who is behind"]')!, "nobody-at-all");
    await sees('Nobody behind matches "nobody-at-all"');
  });

  it("shows a team admin their own teams' people only", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    await sees("1 client last seen: 0 current, 0 behind the recommended version, 1 refused when it next connects.", terminal);
    const table = await waitFor(() => document.querySelector<HTMLTableElement>("table.behind"), "who is behind");
    expect([...table.querySelectorAll("tbody tr")].map((r) => r.querySelector("td")?.textContent)).toEqual(["Fay (fay@example.com)"]);
  });

  it("says how many clients a change holds once it is applied, and the audit records it", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const terminal = await waitFor(() => card("The terminal"), "the terminal's policy");
    button("Change", terminal)!.click();
    type(await waitFor(() => field("Minimum", terminal), "the form"), "0.16.0-beta");
    button("Preview", terminal)!.click();
    (await waitFor(() => button("Apply", terminal), "the preview")).click();

    await sees("Of the clients last seen, 0 are behind it and 3 refused when they next connect.");
    expect(fake.admin.audit.at(-1)).toMatchObject({ action: "clients.put", detail: { affected: { current: 1, behind: 0, refused: 3 } } });
  });

  // #925: after an upgrade, recommend what this plane runs, for every kind of client at once.
  describe("recommending this plane's version", () => {
    const recommend = (): HTMLElement | null => document.querySelector<HTMLElement>('section.recommend[aria-label="Recommend this plane\'s version"]');

    async function onPlane(version: string): Promise<void> {
      await fake.stop();
      fake = await startFake(exampleAdmin(), { version });
    }

    it("is a platform admin's: the button sits above the policies", async () => {
      await onPlane("0.38.0-beta");
      await signedInAs(fake, PEOPLE.alice);
      unmount = render(<App />).unmount;
      const b = await seesButton("Recommend this plane's version");
      const first = document.querySelector("section.card");
      expect(first).not.toBeNull(); // at once: the button is drawn with the cards, in one render
      expect(b.compareDocumentPosition(first!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    });

    it("is nothing to a team admin, not a disabled button", async () => {
      await onPlane("0.38.0-beta");
      await signedInAs(fake, PEOPLE.bob);
      unmount = render(<App />).unmount;
      await waitFor(() => card("The terminal"), "the terminal's policy");
      expect(button("Recommend this plane's version")).toBeNull(); // at once: the cards are drawn, and the button with them or not at all
      expect(says("this plane's version")).toBe(false); // at once: as above
    });

    it("previews every component's recommended version before and after, and how many clients each leaves behind", async () => {
      await onPlane("0.38.0-beta");
      await signedInAs(fake, PEOPLE.alice);
      unmount = render(<App />).unmount;
      (await seesButton("Recommend this plane's version")).click();
      const preview = await waitFor(() => recommend()?.querySelector<HTMLElement>("section.preview"), "the preview");
      const rows = [...preview.querySelectorAll(".recommend-row")].map((r) => r.textContent ?? "");
      expect(rows).toHaveLength(3);
      expect(rows[0]).toContain("clients/tui");
      expect(rows[0]).toContain("recommended: 0.16.0-beta");
      expect(rows[0]).toContain("recommended: 0.38.0-beta");
      expect(rows[0]).toContain("Of 4 clients last seen: 0 current, 2 behind 0.38.0-beta, 2 refused when they next connect, as now.");
      expect(rows[1]).toContain("clients/daemon");
      expect(rows[1]).toContain("recommended: —");
      expect(rows[1]).toContain("Of 1 client last seen: 0 current, 1 behind 0.38.0-beta.");
      expect(rows[2]).toContain("clients/desktop");
      expect(rows[2]).toContain("None has connected since the plane began recording versions.");
      await sees("The terminal: troupe update installs 0.38.0-beta for people signed in here", preview);
      await sees("The desktop app: an older desktop app is told 0.38.0-beta is out.", preview);
      // Nothing is sent until it is confirmed.
      expect(fake.admin.policies["tui"]!.recommended).toBe("0.16.0-beta");
    });

    it("applies the three puts in order and shows one audit note of the three changes", async () => {
      await onPlane("0.38.0-beta");
      await signedInAs(fake, PEOPLE.alice);
      unmount = render(<App />).unmount;
      const recorded = fake.admin.audit.length;
      (await seesButton("Recommend this plane's version")).click();
      (await waitFor(() => button("Apply", recommend()!), "the preview")).click();

      await waitFor(() => says("Recorded in the audit as clients.put on tui, daemon, desktop"), "the audit's note");
      expect(fake.admin.audit.slice(recorded).map((r) => [r.action, r.subject_id])).toEqual([
        ["clients.put", "tui"],
        ["clients.put", "daemon"],
        ["clients.put", "desktop"],
      ]);
      for (const c of ["tui", "daemon", "desktop"]) expect(fake.admin.policies[c]!.recommended).toBe("0.38.0-beta");
      const note = document.querySelector<HTMLElement>(".audit-note")!;
      expect([...note.querySelectorAll("li")].map((l) => l.textContent)).toEqual([
        "tui.recommended 0.16.0-beta → 0.38.0-beta",
        "daemon.recommended — → 0.38.0-beta",
        "desktop.recommended — → 0.38.0-beta",
      ]);
      await sees("The terminal, the daemon and the desktop app now recommend 0.38.0-beta.");
      // Once applied, the button gives way to the line that says so.
      await sees("Every client is recommended this plane's version, 0.38.0-beta.");
      expect(button("Recommend this plane's version")).toBeNull(); // at once: the line replaces it in the same render
    });

    it("says every client is recommended this plane's version where each already is, in place of the button", async () => {
      await onPlane("0.38.0-beta");
      for (const c of ["tui", "daemon", "desktop"]) fake.admin.policies[c] = { ...fake.admin.policies[c]!, recommended: "0.38.0-beta" };
      await signedInAs(fake, PEOPLE.alice);
      unmount = render(<App />).unmount;
      await sees("Every client is recommended this plane's version, 0.38.0-beta.");
      expect(button("Recommend this plane's version")).toBeNull(); // at once: the line is drawn in its place
    });

    it("leaves a component the plane would refuse it for as it is, and says why before anything is sent", async () => {
      await onPlane("0.38.0-beta");
      fake.admin.policies["daemon"] = { ...fake.admin.policies["daemon"]!, blocked: ["0.38.0-beta"] };
      await signedInAs(fake, PEOPLE.alice);
      unmount = render(<App />).unmount;
      const recorded = fake.admin.audit.length;
      (await seesButton("Recommend this plane's version")).click();
      const preview = await waitFor(() => recommend()?.querySelector<HTMLElement>("section.preview"), "the preview");
      await sees("Left as it is, since the plane refuses it while the daemon's policy blocks 0.38.0-beta.", preview);
      expect(preview.querySelectorAll(".recommend-row")).toHaveLength(2);
      button("Apply", preview)!.click();
      await waitFor(() => says("Recorded in the audit as clients.put on tui, desktop"), "the audit's note");
      expect(fake.admin.audit.slice(recorded).map((r) => r.subject_id)).toEqual(["tui", "desktop"]);
      expect(fake.admin.policies["daemon"]!.recommended).toBeNull();
    });

    it("stops at a put the plane refuses, says which and why, and keeps the ones before it", async () => {
      await onPlane("0.38.0-beta");
      await signedInAs(fake, PEOPLE.alice);
      unmount = render(<App />).unmount;
      const recorded = fake.admin.audit.length;
      (await seesButton("Recommend this plane's version")).click();
      const apply = await waitFor(() => button("Apply", recommend()!), "the preview");
      // Somebody raises the daemon's minimum past this plane's version meanwhile.
      fake.admin.policies["daemon"] = { ...fake.admin.policies["daemon"]!, minimum: "0.40.0" };
      apply.click();

      await sees(
        "The terminal now recommends 0.38.0-beta; the daemon's recommended version was not changed: minimum: the minimum 0.40.0 is newer than the recommended version 0.38.0-beta",
        () => recommend(),
      );
      expect(fake.admin.audit.slice(recorded).map((r) => r.subject_id)).toEqual(["tui"]);
      expect(fake.admin.policies["tui"]!.recommended).toBe("0.38.0-beta");
      expect(fake.admin.policies["desktop"]!.recommended).toBeNull();
      await waitFor(() => says("Recorded in the audit as clients.put on tui"), "the note of the one that was applied");
    });

    it("says where the plane's version is not one SemVer reads, with no button", async () => {
      await onPlane("dev");
      await signedInAs(fake, PEOPLE.alice);
      unmount = render(<App />).unmount;
      await sees("which is not a version as releases are numbered, so it cannot be recommended from here.");
      expect(button("Recommend this plane's version")).toBeNull(); // at once: the line is drawn in its place
    });
  });

  it("says when there is no policy at all", async () => {
    fake.admin.policies["tui"] = { recommended: null, minimum: null, blocked: [], updated_by: null, updated_at: null };
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("No policy yet"), "the empty state");
    await sees("This plane serves every version of every client.");
  });
});
