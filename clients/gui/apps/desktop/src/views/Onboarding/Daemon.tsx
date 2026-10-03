// Step 6: whether the daemon starts when the person logs in (troupe Decision 762). Yes
// has the daemon write the platform's own login entry and no has it remove one; what is
// there now is the answer pressed, so a re-run from Setup is also how it is turned off.

import { useState } from "react";
import type { JSX } from "react";
import type { SetupDaemon } from "@troupe/client";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

/** The entry as a person on that platform would recognise it. */
const ENTRY_WORDS: Record<SetupDaemon["kind"], string> = {
  startup_folder: "an entry in your Startup folder, which runs it in a console window minimised to the taskbar; closing that window stops it",
  launch_agent: "a launchd agent in your LaunchAgents folder",
  systemd: "a systemd user unit",
  autostart: "an autostart entry, which your desktop session starts",
};

export function Daemon({ flow, busy, error, onAnswer, onBack }: StepProps): JSX.Element {
  const status = flow.daemon ?? null;
  const earlier = flow.answers.daemon?.["at_login"];
  const [atLogin, setAtLogin] = useState<boolean>(typeof earlier === "boolean" ? earlier : (status?.at_login ?? false));
  const startable = status?.command != null;

  return (
    <StepFrame
      flow={flow}
      title="Start Troupe when you log in?"
      lede="The daemon on this computer runs your sessions. An app starts it when it needs it, and it stops by itself a while after the last one closes. Started when you log in, it is already there when you open one, and stays up until you log out."
      error={error}
    >
      <div className="options">
        <button type="button" className="option" aria-pressed={!atLogin} onClick={() => setAtLogin(false)}>
          <span className="label">
            Only when an app needs it
            <span className="micro"> · default</span>
          </span>
          <span className="consequence">Nothing is added to what starts when you log in{status?.at_login ? ", and the entry there now is removed" : ""}.</span>
        </button>
        <button type="button" className="option" aria-pressed={atLogin} onClick={() => setAtLogin(true)} disabled={!startable && !atLogin}>
          <span className="label">Start it when I log in</span>
          <span className="consequence">
            {startable && status
              ? `Adds ${ENTRY_WORDS[status.kind]}. It starts ${status.command} from your next login; nothing starts now.`
              : "troupe-daemon is not on this computer's PATH, so there is nothing to start. Install it, then come back to Setup."}
          </span>
        </button>
      </div>

      {status && (
        <p className="copy" style={{ margin: 0, maxWidth: "var(--measure-reading)", color: "var(--text-secondary)" }}>
          {status.at_login ? "It starts at login now, from " : "Its entry would be "}
          <code className="mono">{status.path}</code>. <code className="mono">troupe daemon login off</code> takes it out from a terminal.
        </p>
      )}

      <Actions busy={busy} next="Continue" onBack={onBack} onNext={() => onAnswer({ at_login: atLogin })} />
    </StepFrame>
  );
}
