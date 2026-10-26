// Steering a session from another device, through the plane (troupe #58).
//
// Two halves, one in each session's head. On this computer's own session, the offer:
// the people it is shared with and at what, whether the plane has it now, who is steering
// it from elsewhere, and the withdrawal, which ends every one of those views at once. On a
// laptop's session opened from here, whose laptop it is, and since when it is away when it
// is. What the daemon says is what is shown: its answer at once, then each listing; and who
// is steering is the session's presence as it happens, somebody attached through the plane
// arriving or leaving, over the daemon's own connection.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { PRIVATE_OFFER_SENTENCE, RESTART_SENTENCE, invitationWords, offerRestartWords, remoteOffer, remoteWhen, steerWords } from "@troupe/client";
import type { DaemonClient, FleetRow, Invitation, PresenceMember, RemoteOffer, RemotePerson } from "@troupe/client";

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

/**
 * Who is steering now: the listing's word, with what the session's presence said since,
 * somebody through the plane who arrived added and one who left taken off. Presence starts
 * from when this view subscribed, so the listing says who was there before.
 */
export function steeringNow(listed: RemotePerson[], presence: PresenceMember[]): RemotePerson[] {
  const relayed = presence.filter((p) => p.via === "plane");
  const heard = new Map(relayed.map((p) => [p.subject, p.state]));
  const kept = listed.filter((p) => heard.get(p.subject) !== "left");
  const came = relayed
    .filter((p) => p.state !== "left" && !kept.some((k) => k.subject === p.subject))
    .map((p) => ({ subject: p.subject, display_name: p.display_name ?? null, role: "control" }));
  return [...kept, ...came];
}

/** The plane's word on whether the laptop is there. */
export function presenceWords(offer: RemoteOffer): string {
  if (offer.state === "online") return "Online";
  if (offer.state === "connecting") return "Connecting to the plane";
  return offer.since ? `Offline since ${remoteWhen(offer.since)}` : "Offline";
}

/**
 * This computer's offer in words: whether the plane has it, then whether it came back
 * after a restart or lasts only until one, as the terminal's `/steer` says it. A private
 * session's says so first.
 */
export function offerWords(offer: RemoteOffer): string {
  return [...(offer.private ? ["Private"] : []), presenceWords(offer), ...offerRestartWords(offer)].join(" · ");
}

/**
 * Who invited this person, and for a private session what the invitation lets them do now:
 * "Ada invited you to steer it · offered · you can steer".
 */
export function inviteLine(i: Invitation): string {
  const now = steerWords(i);
  return now ? `${invitationWords(i)} · ${now}` : invitationWords(i);
}

/**
 * This computer's session, offered to the plane or not. A private one is offered only after
 * its person says yes to its passing through the plane unsealed while it is, in the words
 * the terminal asks with; it is shared with the people invited into it with control, and
 * withdrawing it makes it sealed-only again (troupe #765).
 */
export function RemoteOfferControl({ daemon, row, presence = [] }: { daemon: DaemonClient; row: FleetRow; presence?: PresenceMember[] }): JSX.Element | null {
  const [offer, setOffer] = useState<RemoteOffer | null>(row.remote ?? null);
  const [open, setOpen] = useState(false);
  const [share, setShare] = useState(() => (row.remote?.shares ?? []).map((p) => p.email ?? p.subject).join(", "));
  const [role, setRole] = useState<Role>((row.remote?.shares[0]?.role as Role | undefined) ?? "control");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Said once, as the offer is made, where nothing starts the daemon at login.
  const [restart, setRestart] = useState(false);
  // A private session's question, asked before anything is offered.
  const [asking, setAsking] = useState(false);

  // The listing catches up with what was done here, and with what another client did.
  useEffect(() => setOffer(row.remote ?? null), [row.remote]);

  if (row.kind !== "local" && row.kind !== "private") return null;
  const isPrivate = row.kind === "private";

  const act = async (f: () => Promise<{ remote: unknown }>, offering = false): Promise<void> => {
    setBusy(true);
    setError(null);
    setRestart(false);
    try {
      const answer = await f();
      const made = remoteOffer(answer.remote);
      setOffer(made);
      setRestart(offering && made?.lasts === "until_restart");
      setOpen(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const offerIt = (): Promise<void> =>
    act(() => daemon.offerRemote(row.id, people(share).map((person) => ({ person, role }))), true);
  // Only the person's yes offers a private session, to the people it invited with control.
  const offerPrivate = (): Promise<void> => {
    setAsking(false);
    return act(() => daemon.offerRemote(row.id, [], "private"), true);
  };
  const withdraw = (): Promise<void> => act(() => daemon.withdrawRemote(row.id));
  const steering = offer ? steeringWords({ ...offer, steering: steeringNow(offer.steering, presence) }) : null;

  return (
    <div className="remote-offer" role="group" aria-label="Steer from elsewhere">
      {offer ? (
        <>
          <span className="pill" title={offerWords(offer)}>
            Offered · {offerWords(offer)}
          </span>
          {steering && <span className="steering">{steering}</span>}
          {!isPrivate && (
            <button className="tab" onClick={() => setOpen((o) => !o)} aria-expanded={open} disabled={busy}>
              Share
            </button>
          )}
          <button className="tab" onClick={() => void withdraw()} disabled={busy}>
            Withdraw
          </button>
        </>
      ) : (
        <button className="tab" onClick={() => (isPrivate ? setAsking((a) => !a) : setOpen((o) => !o))} aria-expanded={isPrivate ? asking : open} disabled={busy}>
          Steer from elsewhere
        </button>
      )}

      {isPrivate && asking && !offer && (
        <div className="remote-consent" role="alertdialog" aria-label="Offer a private session">
          <p>{PRIVATE_OFFER_SENTENCE}</p>
          <button className="primary" onClick={() => void offerPrivate()} disabled={busy}>
            Offer it
          </button>
          <button className="tab" onClick={() => setAsking(false)} disabled={busy}>
            Keep it sealed
          </button>
        </div>
      )}

      {open && !isPrivate && (
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

      {offer && restart && (
        <p className="also" role="status">
          {RESTART_SENTENCE}
        </p>
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
      {row.remote.private ? " · private, passing through the plane unsealed while it is offered" : ""}
    </span>
  );
}
