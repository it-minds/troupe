// The app's own update, in one line at the top (#66, Decision 874).
//
// Quiet while it is an offer — a newer release, or the version the plane recommends — and
// in the refusal's colour when the plane does not serve this version, which is the one
// time the line cannot be put away. Each step says what it will do before it does it:
// downloading checks the release against its signature; restarting is asked for, and
// waits for a turn on this computer to end.

import type { JSX } from "react";
import type { UpdateOffer } from "../shell";
import type { Updates } from "../updates";

function daemonLine(offer: UpdateOffer): string | null {
  if (offer.daemon) return `troupe-daemon ${offer.daemon.from} is replaced with it, between turns.`;
  return offer.daemon_note;
}

export function UpdateBanner({ updates }: { updates: Updates }): JSX.Element | null {
  const { phase, required, suggest } = updates;
  if (updates.dismissed && !required) return null;

  const tone = required ? "required" : phase.kind === "refused" ? "refused" : "quiet";
  const offered = phase.kind === "offer" ? phase.offer : null;
  if (!required && !suggest && phase.kind === "idle") return null;
  // A suggestion with nothing the shell can install is still said, once, as a line.
  const lead = required ?? suggest ?? (offered ? `Troupe ${offered.version} is available; this is ${offered.current}.` : null);

  let body: JSX.Element | null = null;
  switch (phase.kind) {
    case "idle":
    case "offer":
      body = (
        <>
          {lead && <p>{lead}</p>}
          {offered && daemonLine(offered) && <p className="micro">{daemonLine(offered)}</p>}
          {updates.canUpdate && (required || offered) && (
            <button className="link" onClick={updates.update}>
              {required ? "Update now" : "Update"}
            </button>
          )}
          {!required && (
            <button className="link" onClick={updates.later}>
              Later
            </button>
          )}
        </>
      );
      break;
    case "downloading": {
      const share = phase.total ? ` · ${Math.floor((phase.received / phase.total) * 100)}%` : "";
      body = (
        <>
          {required && <p>{required}</p>}
          <p>
            Downloading Troupe {phase.offer.version} and checking it against the release key{share}…
          </p>
        </>
      );
      break;
    }
    case "ready":
      body = (
        <>
          {required && <p>{required}</p>}
          <p>
            Troupe {phase.offer.version} is downloaded and checked against the release key. Restarting closes this window
            {phase.offer.daemon ? " and replaces troupe-daemon once no turn is at work" : ""}; sessions keep their place.
          </p>
          <button className="link" onClick={updates.restart}>
            Restart now
          </button>
          {!required && (
            <button className="link" onClick={updates.later}>
              Later
            </button>
          )}
        </>
      );
      break;
    case "waiting":
      body = (
        <>
          {required && <p>{required}</p>}
          <p>{phase.why}</p>
        </>
      );
      break;
    case "installing":
      body = <p>Restarting into Troupe {phase.offer.version}…</p>;
      break;
    case "refused":
      body = (
        <>
          {required && <p>{required}</p>}
          <p>{phase.sentence}</p>
          {!required && (
            <button className="link" onClick={updates.later}>
              Later
            </button>
          )}
        </>
      );
      break;
  }

  return (
    <div className={`banner update ${tone}`} role={required ? "alert" : "status"}>
      {body}
    </div>
  );
}
