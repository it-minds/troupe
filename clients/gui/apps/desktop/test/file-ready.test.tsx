// A file the agent made for the person (troupe #765): `file_ready` is a line in the stream
// with the file's path and a Save…, which reads the bytes with `fs.read` from wherever the
// session runs and hands them to the shell's save dialog, the line saying where they went.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;
let saved: Array<{ name: string; content: string }>;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  saved = [];
  // The shell's half: the system's save dialog, which here takes what it is given.
  window.troupe = {
    name: "test shell",
    version: "0.0.0",
    saveFile: async (name, content) => {
      saved.push({ name, content });
      return `/home/ada/Documents/${name}`;
    },
  };
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete window.troupe;
  await daemon.stop();
});

const line = (): HTMLElement | null => document.querySelector(".stream .file-ready");

describe("a file the agent made", () => {
  it("is a line with its path and a Save… that reads it and saves it where the person chose", async () => {
    startOnTheList();
    const session = daemon.seed("/home/ada/reports");
    daemon.files.set("out/q3.md", "# Q3\n");
    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/ada/reports")),
      "the session in the list",
    );
    row.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");

    session.log.append("file_ready", { path: "out/q3.md", size: 5, hash: "sha256:ab", local_path: "/home/ada/reports/out/q3.md" });
    const shown = await waitFor(line, "the file line");
    // On this machine it is already where the line says.
    expect(shown.querySelector("code")?.textContent).toBe("/home/ada/reports/out/q3.md");

    const save = [...shown.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === "Save…")!;
    save.click();
    await waitFor(() => line()?.textContent?.includes("saved to /home/ada/Documents/q3.md"), "where it was saved");
    expect(saved).toEqual([{ name: "q3.md", content: "# Q3\n" }]);
    expect(daemon.calls.filter((c) => c.method === "fs.read").map((c) => c.params["path"])).toEqual(["out/q3.md"]);
  });
});
