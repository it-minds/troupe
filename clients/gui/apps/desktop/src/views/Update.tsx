// The app's own update, in one line at the top (#66, Decision 874).
//
// Quiet while it is an offer — a newer release, or the version the plane recommends — and
// in the refusal's colour when the plane does not serve this version, which is the one
// time the line cannot be put away. Each step says what it will do before it does it:
// downloading checks the release against its signature; restarting is asked for, and
// waits for a turn on this computer to end. Above all of it, a plane whose signing key has
// changed since this computer pinned it, which asks its person to accept the new one.

import type { JSX } from "react";
import type { UpdateOffer } from "../shell";
import type { Updates } from "../updates";

function daemonLine(offer: UpdateOffer): string | null {
  if (offer.daemon) return `troupe-daemon ${offer.daemon.from} is replaced with it, between turns.`;
  return offer.daemon_note;
}

/**
 * The plane signing with a key other than the one this computer pinned (#657): both
 * fingerprints, and the person's yes, after they have checked the new one with the plane's
 * administrators. Until then nothing it signs is acted on.
 */
function PlaneKeyBanner({ change }: { change: NonNullable<Updates["planeKey"]> }): JSX.Element {
  return (
    <div className="banner update refused" role="alert">
      <p>
        This plane now signs what it tells this computer with the key <code>{change.offered}</code>, not <code>{change.pinned}</code>, the one pinned when you
        signed in. Its version policy and its organisation's settings are not taken until you accept the new key.
      </p>
      <p className="micro">Check the fingerprint with the plane's administrators first: their console shows it under Configure → Integrations.</p>
      {change.error && <p className="micro">{change.error}</p>}
      <button className="link" onClick={change.accept}>
        Accept the new key
      </button>
    </div>
  );
}

export function UpdateBanner({ updates }: { updates: Updates }): JSX.Element | null {
  if (updates.planeKey) return <PlaneKeyBanner change={updates.planeKey} />;
  const { phase, required, suggest } = updates;
  if (updates.dismissed && !required) return null;

  const tone = required ? "required" : phase.kind === "refused" ? "refused" : "quiet";
  const offered = phase.kind === "offer" ? phase.offer : null;
  if (!required && !suggest && !updates.signatureLine && phase.kind === "idle") return null;
  // A suggestion with nothing the shell can install is still said, once, as a line; so is a
  // policy the plane's key did not sign, which the update then does without.
  const lead = required ?? suggest ?? (offered ? `Troupe ${offered.version} is available; this is ${offered.current}.` : updates.signatureLine);

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
