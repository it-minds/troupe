// Steering a session from another device, through the plane (troupe #58, Decision 921).
//
// Two halves, one in each session's head. On this computer's own session, the offer:
// the people it is shared with and at what, whether the plane has it now, who is steering
// it from elsewhere, and the withdrawal, which ends every one of those views at once. On a
// laptop's session opened from here, whose laptop it is, and since when it is away when it
// is. What the daemon says is what is shown: its answer at once, then each listing.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { remoteOffer, remoteWhen } from "@troupe/client";
import type { DaemonClient, FleetRow, RemoteOffer } from "@troupe/client";

type Role = "observe" | "control";

/** People as a person types them: subjects or emails, by commas or spaces. */
function people(text: string): string[] {
  return text
    .split(/[\s,]+/)
    .map((p) => p.trim())
    .filter((p) => p !== "");
}

/** Who is steering, in a sentence. */
export function steeringWords(offer: RemoteOffer): string | null {
  const names = offer.steering.map((p) => p.display_name ?? p.subject);
  if (names.length === 0) return null;
  return names.length === 1 ? `${names[0]} is steering from another device` : `${names.join(", ")} are steering from other devices`;
}

/** The plane's word on whether the laptop is there. */
export function presenceWords(offer: RemoteOffer): string {
  if (offer.state === "online") return "Online";
  if (offer.state === "connecting") return "Connecting to the plane";
  return offer.since ? `Offline since ${remoteWhen(offer.since)}` : "Offline";
}

/**
 * This computer's session, offered to the plane or not. Only a local session has it: a
 * private one is sealed under its person's key and never offered.
 */
export function RemoteOfferControl({ daemon, row }: { daemon: DaemonClient; row: FleetRow }): JSX.Element | null {
  const [offer, setOffer] = useState<RemoteOffer | null>(row.remote ?? null);
  const [open, setOpen] = useState(false);
  const [share, setShare] = useState(() => (row.remote?.shares ?? []).map((p) => p.email ?? p.subject).join(", "));
  const [role, setRole] = useState<Role>((row.remote?.shares[0]?.role as Role | undefined) ?? "control");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // The listing catches up with what was done here, and with what another client did.
  useEffect(() => setOffer(row.remote ?? null), [row.remote]);

  if (row.kind !== "local") return null;

  const act = async (f: () => Promise<{ remote: unknown }>): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const answer = await f();
      setOffer(remoteOffer(answer.remote));
      setOpen(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const offerIt = (): Promise<void> =>
    act(() => daemon.offerRemote(row.id, people(share).map((person) => ({ person, role }))));
  const withdraw = (): Promise<void> => act(() => daemon.withdrawRemote(row.id));
  const steering = offer ? steeringWords(offer) : null;

  return (
    <div className="remote-offer" role="group" aria-label="Steer from elsewhere">
      {offer ? (
        <>
          <span className="pill" title={presenceWords(offer)}>
            Offered · {presenceWords(offer)}
          </span>
          {steering && <span className="steering">{steering}</span>}
          <button className="tab" onClick={() => setOpen((o) => !o)} aria-expanded={open} disabled={busy}>
            Share
          </button>
          <button className="tab" onClick={() => void withdraw()} disabled={busy}>
            Withdraw
          </button>
        </>
      ) : (
        <button className="tab" onClick={() => setOpen((o) => !o)} aria-expanded={open} disabled={busy}>
          Steer from elsewhere
        </button>
      )}

      {open && (
        <form
          className="remote-share"
          onSubmit={(e) => {
            e.preventDefault();
            void offerIt();
          }}
        >
          <p>
            Offer this session to the plane, so you can steer it from your other devices. The people you name can too.
            Nothing listens on this computer: it keeps one connection to the plane while the session is offered.
          </p>
          <label>
            Share with
            <input value={share} onChange={(e) => setShare(e.target.value)} placeholder="ann@example.com, bo@example.com" />
          </label>
          <label>
            They may
            <select value={role} onChange={(e) => setRole(e.target.value as Role)}>
              <option value="control">Steer it</option>
              <option value="observe">Follow it</option>
            </select>
          </label>
          <button type="submit" disabled={busy}>
            {offer ? "Share" : "Offer it"}
          </button>
        </form>
      )}

      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}

/** A laptop's session opened from here: whose laptop, and whether it is there. */
export function RemoteLine({ row }: { row: FleetRow }): JSX.Element | null {
  if (row.kind !== "remote" || !row.remote) return null;
  const whose = row.yourRole === "owner" ? "your laptop" : `${row.remote.ownerName ?? row.owner ?? "somebody"}'s laptop`;
  return (
    <span className="remote-line" title="Steered from here through the plane">
      On {whose} · {presenceWords(row.remote)}
    </span>
  );
}
