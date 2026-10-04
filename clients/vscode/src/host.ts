// The one sentence that says Troupe is not there, and which machine it was looked for on.
//
// In a remote window (WSL, SSH, a dev container, a codespace) the terminal runs on the
// remote host, so that is where `troupe` has to be installed; "not found" without saying
// where would send a person to install it again on the laptop, where it already is.

import type { Missing } from "./binary.js";

/** The install instructions, for the button beside the sentence. */
export const INSTALL_URL = "https://it-minds.github.io/troupe/quick-start/#1-install";

/**
 * Where the extension, and so the terminal, runs: "on this computer", or the remote host as
 * VS Code's remote indicator names it, with the preposition that goes before it.
 */
export function machineName(
  remoteName: string | undefined,
  env: Readonly<Record<string, string | undefined>>,
  hostname: string,
): string {
  switch (remoteName) {
    case undefined:
    case "":
      return "on this computer";
    case "wsl":
      return `in WSL: ${env["WSL_DISTRO_NAME"] || hostname}`;
    case "ssh-remote":
      return `on SSH: ${hostname}`;
    case "dev-container":
    case "attached-container":
      return `in the container ${hostname}`;
    case "codespaces":
      return "in this codespace";
    default:
      return `on ${remoteName}: ${hostname}`;
  }
}

export function missingMessage(missing: Missing, where: string): string {
  return missing.missing === "setting"
    ? `There is no troupe to run at ${missing.setting}, which troupe.path names, ${where}.`
    : `Troupe isn't installed ${where} (no troupe on the PATH, nor where the installer puts it).`;
}
