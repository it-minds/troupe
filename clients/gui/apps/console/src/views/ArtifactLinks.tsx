// An artifact's links, for its owner: make one, see who the plane signed in through each,
// and revoke a link or one person.
//
// A link honours the plane's sign-in: whoever opens it is signed in at the plane first, and
// only then holds its role on this one artifact, `view`, `comment` or `edit`. It widens nothing for
// anybody who does not hold it. Its address is shown once, when it is made; the plane keeps
// only a hash of it. A public link, which opens without a sign-in, can be made only where an
// administrator turned public links on, is view only and always expires; the owner can
// switch this artifact's public links off at any time.

import { useState } from "react";
import type { JSX } from "react";
import { appLink } from "@troupe/client";
import type { ArtifactApi, ArtifactDetail, ArtifactNewLink, ArtifactShare, ArtifactShareRole } from "@troupe/client";
import { describeError, useConsole } from "../console";
import { Field, Region, ShownOnce, when } from "./bits";

const ROLE: Record<string, string> = { view: "View", comment: "Comment: may write in its comments", edit: "Edit: may publish new versions" };

/** A date input's day as the end of that day, in ISO 8601: what a link's expiry is sent as. */
function endOfDay(day: string): string | undefined {
  if (!day) return undefined;
  const at = new Date(`${day}T23:59:59`);
  return Number.isNaN(at.getTime()) ? undefined : at.toISOString();
}

export function ArtifactLinks({ artifact: a, api, reload }: { artifact: ArtifactDetail; api: ArtifactApi; reload: () => void }): JSX.Element {
  const { notify, plane } = useConsole();
  const [role, setRole] = useState<ArtifactShareRole>("view");
  const [expires, setExpires] = useState("");
  const [pub, setPub] = useState(false);
  const [made, setMade] = useState<ArtifactNewLink | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const shares = a.shares ?? [];
  const allowed = a.public_links_allowed === true;

  const act = (work: Promise<unknown>, done: string): void => {
    setBusy(true);
    setError(null);
    work.then(
      () => {
        setBusy(false);
        notify(done);
        reload();
      },
      (e: unknown) => {
        setBusy(false);
        setError(e);
      },
    );
  };

  const make = (): void => {
    const at = endOfDay(expires);
    setBusy(true);
    setError(null);
    api.share(a.id, { role: pub ? "view" : role, ...(at ? { expires: at } : {}), ...(pub ? { public: true } : {}) }).then(
      (link) => {
        setBusy(false);
        setMade(link);
      },
      (e: unknown) => {
        setBusy(false);
        setError(e);
      },
    );
  };

  return (
    <section aria-label="Links">
      <Region>Links</Region>
      <p className="lead">A link signs whoever opens it in at this plane first, and gives them its role on {a.title} alone. Nobody who does not hold it gains anything by it.</p>
      {made && (
        <ShownOnce label={made.share.public ? "The public link" : "The link"} value={made.share.public ? made.url : `${made.url}\n${appLink({ kind: "artifact", id: a.id, plane: plane.url })}`}>
          {/* The app's own link carries nothing of the link's key: it opens the artifact for
              whoever already holds a role on it, which the first line gives them. A public
              link's reader may have no sign-in here, so it is not offered with one. */}
          {!made.share.public && <p className="hint">The second line opens it in the Troupe app, once the first has been opened.</p>}
          <div className="actions">
            <button
              type="button"
              onClick={() => {
                setMade(null);
                reload();
              }}
            >
              Done
            </button>
          </div>
        </ShownOnce>
      )}
      <form
        className="edit"
        aria-label="Make a link"
        onSubmit={(e) => {
          e.preventDefault();
          make();
        }}
      >
        <Field label="Role">
          {(p) => (
            <select {...p} value={pub ? "view" : role} disabled={pub} onChange={(e) => setRole(e.target.value === "edit" || e.target.value === "comment" ? e.target.value : "view")}>
              <option value="view">{ROLE.view}</option>
              <option value="comment">{ROLE.comment}</option>
              <option value="edit">{ROLE.edit}</option>
            </select>
          )}
        </Field>
        <Field label="Expires" hint={pub ? "A public link must expire, within 90 days." : "Leave it empty for a link that lasts until it is revoked."}>
          {(p) => <input {...p} type="date" value={expires} onChange={(e) => setExpires(e.target.value)} />}
        </Field>
        {allowed && (
          <label className="inline">
            <input type="checkbox" checked={pub} onChange={(e) => setPub(e.target.checked)} /> Public: opens for anybody who has it, signed in or not
          </label>
        )}
        {error !== null && (
          <p className="field-error" role="alert">
            {describeError(error)}
          </p>
        )}
        <div className="actions">
          <button type="submit" className="primary" disabled={busy || (pub && !expires)}>
            {pub ? "Make a public link" : "Make a link"}
          </button>
          {!allowed && <span className="hint">Public links are switched off on this plane.</span>}
        </div>
      </form>
      {allowed && (
        <p>
          Public links for this artifact are <b>{a.public_links === false ? "off" : "on"}</b>.{" "}
          <button type="button" disabled={busy} onClick={() => act(api.publicLinks(a.id, a.public_links === false), a.public_links === false ? "Its public links open again." : "Its public links no longer open.")}>
            {a.public_links === false ? "Turn them on" : "Turn them off"}
          </button>
        </p>
      )}
      {shares.length === 0 ? (
        <p className="note">No link has been made to it.</p>
      ) : (
        <ul className="artifact-links" aria-label="Its links">
          {shares.map((s) => (
            <Link key={s.id} share={s} busy={busy} onRevoke={() => act(api.unshare(a.id, { share: s.id }), "The link is revoked.")} onRevokePerson={(subject) => act(api.unshare(a.id, { person: subject }), `${subject} no longer holds it.`)} />
          ))}
        </ul>
      )}
    </section>
  );
}

function Link({ share: s, busy, onRevoke, onRevokePerson }: { share: ArtifactShare; busy: boolean; onRevoke: () => void; onRevokePerson: (subject: string) => void }): JSX.Element {
  return (
    <li aria-label={`${s.public ? "Public link" : "Link"} ${s.id}`}>
      <header>
        <b>{s.public ? "Public, view" : ROLE[s.role]}</b>
        <span className="muted">
          {" "}
          · {s.state} · made {when(s.created_at)} · {s.expires_at ? `expires ${when(s.expires_at)}` : "no expiry"}
        </span>
        {s.state === "live" && (
          <button type="button" className="danger" disabled={busy} onClick={onRevoke}>
            Revoke the link
          </button>
        )}
      </header>
      {s.used_by.length === 0 ? (
        <p className="note">{s.public ? "A public link signs nobody in, so it records nobody." : "Nobody has been signed in through it yet."}</p>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Who</th>
                <th>First</th>
                <th>Last</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {s.used_by.map((u) => (
                <tr key={u.person.subject}>
                  <td>{u.person.display_name ?? u.person.subject}</td>
                  <td>{when(u.first_used_at)}</td>
                  <td>{when(u.last_used_at)}</td>
                  <td>
                    {u.revoked_at ? (
                      <span className="muted">revoked</span>
                    ) : (
                      <button type="button" disabled={busy} onClick={() => onRevokePerson(u.person.subject)}>
                        Revoke {u.person.display_name ?? u.person.subject}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </li>
  );
}
