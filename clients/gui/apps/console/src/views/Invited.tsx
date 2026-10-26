// Sessions somebody invited you into by name (troupe #765), on Mine.
//
// The plane's word as it changes: the invitations ride the person's watch beside the
// laptops' offers (`invites.changed`), so one made or taken back is shown as it happens.
// A pod session is opened from here as the desktop app opens one, to follow it or to steer
// it as the invitation says, and closes with a sentence once the invitation is taken back.
// A private session is not opened here: its log is sealed under its owner's key, and only
// the invitee's own machine opens the copy of the key put in their slot. A page the plane
// serves cannot, which is the point: the plane that serves this page cannot read it either.
// While its owner offers it for steering, having said yes to its passing through the plane
// unsealed, somebody invited with control steers it from here through the relay, as any
// laptop's offered session; the row says which it is now.

import { useRef } from "react";
import type { JSX } from "react";
import { invitationWords, remoteWhen, removedSentence, steerWords } from "@troupe/client";
import type { Invitation } from "@troupe/client";
import type { Load } from "../console";
import { href } from "../route";
import { Empty, Loaded } from "./bits";
import { RemoteSession, useOffered } from "./Remote";

/** Invited to you, on Mine. */
export function InvitedToYou({ load, reload }: { load: Load<Invitation[]>; reload: () => void }): JSX.Element {
  return (
    <section className="invited" aria-label="Invited to you">
      <h2>Invited to you</h2>
      <p className="note">Sessions somebody invited you into by name, to follow or to steer. You act in them as yourself, under the session's own rules.</p>
      <Loaded load={load} what="the sessions you were invited into" retry={reload}>
        {(rows) =>
          rows.length === 0 ? (
            <Empty title="Nobody has invited you into a session">One appears here as soon as somebody invites you, and goes when they take it back.</Empty>
          ) : (
            <table className="sessions invited">
              <thead>
                <tr>
                  <th>Session</th>
                  <th>Whose</th>
                  <th>You may</th>
                  <th>Invited</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((i) => (
                  <tr key={i.session_id}>
                    <td className="mono">
                      {i.kind === "private" ? (
                        <span title="Sealed under its owner's key: open it in the desktop app on your computer, which reads it with your own key">
                          {i.title ?? i.session_id}
                        </span>
                      ) : (
                        <a href={href({ page: "mine", path: ["invited", i.session_id] })}>{i.title ?? i.session_id}</a>
                      )}
                    </td>
                    <td>
                      {i.owner_name ?? i.owner}
                      {i.kind === "private" ? " · private: read it in the desktop app" : i.profile ? ` · ${i.profile}` : ""}
                    </td>
                    <td>
                      {i.kind === "private" && i.role === "control" ? (
                        i.offered ? (
                          <a href={href({ page: "mine", path: ["remote", i.session_id] })}>{steerWords(i)}</a>
                        ) : (
                          steerWords(i)
                        )
                      ) : i.role === "control" ? (
                        "steer it"
                      ) : (
                        "follow it"
                      )}
                    </td>
                    <td>
                      {invitationWords(i)}, {remoteWhen(i.invited_at)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )
        }
      </Loaded>
    </section>
  );
}

/**
 * A pod session opened from an invitation: followed or steered as it says, and closed with
 * a sentence once it is taken back.
 */
export function InvitedSession({ id }: { id: string }): JSX.Element {
  const [, , invites] = useOffered();
  // Whose it was, for the sentence once it is taken back.
  const seen = useRef<Invitation | null>(null);
  if (invites.state !== "ready") return <p role="status">Looking for your invitation…</p>;
  const invitation = invites.data.find((i) => i.session_id === id);
  if (invitation) seen.current = invitation;
  if (!invitation) {
    return (
      <div className="page remote-session">
        <p className="crumbs">
          <a href={href({ page: "mine" })}>← Mine</a> · <span className="mono">{id}</span>
        </p>
        <Empty title="Not shared with you">
          {seen.current ? removedSentence(seen.current.owner_name ?? seen.current.owner) : "Nobody has invited you into this session."}
        </Empty>
      </div>
    );
  }
  if (invitation.kind === "private") {
    return (
      <Empty title="Read it on your own computer">
        This private session is sealed under its owner's key. The desktop app reads it with your own key, which only your machine can open.
        {invitation.role === "control" && invitation.offered ? " Its owner offers it for steering now: steer it from Offered to you from laptops." : ""}
      </Empty>
    );
  }
  return (
    <RemoteSession
      id={id}
      pod={{ mode: invitation.role === "control" ? "activate" : "read", whose: invitation.owner_name ?? invitation.owner }}
    />
  );
}
