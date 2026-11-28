// Who reads an artifact and its links, for its owner: who reads it as one menu (its teams,
// its people and the organisation switch, saved at once and kept across its versions; a
// platform admin's too), and its links: make one, see who the plane signed in through each,
// and revoke a link or one person.
//
// A link honours the plane's sign-in: whoever opens it is signed in at the plane first, and
// only then holds its role on this one artifact, `view`, `comment` or `edit`. It widens nothing for
// anybody who does not hold it. Its address is shown once, when it is made; the plane keeps
// only a hash of it. A public link, which opens without a sign-in, can be made only where an
// administrator turned public links on, is view only and always expires; the owner can
// switch this artifact's public links off at any time.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { accessChanges, accessWaiting, artifactAccessWords, artifactLinkText } from "@troupe/client";
import type { ArtifactAccess, ArtifactAccessChange, ArtifactApi, ArtifactDetail, ArtifactNewLink, ArtifactShare, ArtifactShareRole, Person } from "@troupe/client";
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
        <ShownOnce label={made.share.public ? "The public link" : "The link"} value={made.share.public ? made.url : artifactLinkText(made.url, a.id, plane.url, plane.app)}>
          {/* The app's own link carries nothing of the link's key: it opens the artifact for
              whoever already holds a role on it, which the first line gives them. A public
              link's reader may have no sign-in here, so it is not offered with one. */}
          {!made.share.public && <p className="hint">{plane.app ? "The second line opens it in the Troupe app, once the first has been opened; the third in a browser, for somebody without the app." : "The second line opens it in the Troupe app, once the first has been opened."}</p>}
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

/** A person in the Access menu's draft: who, and the role they will have once it is saved. */
interface Reader {
  subject: string;
  display_name?: string | null;
  role: ArtifactShareRole;
}

/**
 * Who reads it (troupe #1238), for its owner, or a platform admin, to change: one menu, as
 * the desktop app's Access tab has it. The teams as checkboxes, those granted the profile its
 * session ran on first and then the owner's other teams, and a team that reads it but is
 * neither shown as it is, with why; the people it is shared with by name at their roles, and
 * a picker that finds people who share a team with the owner and those its session's profile
 * covers; the organisation switch where the plane allows it. Save sends each part changed
 * whole (`artifact.access.set`), which the plane applies as the difference and makes no
 * version of, and says what changed; a refusal is said here with the draft kept, and a change
 * that waits on a team administrator says so. Its links are the section below it.
 */
export function ArtifactAccessMenu({ artifact: a, api, organisationAllowed, reload }: { artifact: ArtifactDetail; api: ArtifactApi; organisationAllowed: boolean; reload: () => void }): JSX.Element {
  const { notify } = useConsole();
  const [access, setAccess] = useState<ArtifactAccess | null>(null);
  const [loadError, setLoadError] = useState<unknown>(null);
  const [granted, setGranted] = useState<string[]>([]);
  const [teams, setTeams] = useState<string[]>([]);
  const [people, setPeople] = useState<Reader[]>([]);
  const [organisation, setOrganisation] = useState(false);
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<Person[]>([]);
  const [role, setRole] = useState<ArtifactShareRole>("view");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [said, setSaid] = useState<string | null>(null);
  const profile = a.origin?.profile ?? null;

  const take = (got: ArtifactAccess): void => {
    setAccess(got);
    setTeams(got.teams.map((t) => t.name));
    setPeople(got.people.map((p) => ({ subject: p.subject, display_name: p.display_name ?? null, role: p.role })));
    setOrganisation(got.organisation);
  };

  useEffect(() => {
    let live = true;
    api.getAccess(a.id).then(
      (got) => live && take(got),
      (e: unknown) => live && setLoadError(e),
    );
    return () => {
      live = false;
    };
  }, [api, a.id]);

  useEffect(() => {
    if (!profile) return;
    let live = true;
    api.profileTeams(profile).then(
      (r) => live && setGranted(r.teams),
      () => live && setGranted([]),
    );
    return () => {
      live = false;
    };
  }, [api, profile]);

  useEffect(() => {
    const q = query.trim();
    if (q === "") return setFound([]);
    let live = true;
    const t = setTimeout(() => {
      api.searchPeople(q, { artifact: a.id }).then(
        (r) => live && setFound(r.people.filter((p) => !people.some((s) => s.subject === p.subject))),
        () => live && setFound([]),
      );
    }, 150);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [api, a.id, query, people.length]);

  if (!access) {
    return (
      <section aria-label="Who reads it">
        <Region>Who reads it</Region>
        {loadError !== null ? (
          <p className="field-error" role="alert">
            {describeError(loadError)}
          </p>
        ) : (
          <p className="note">Reading who reads it…</p>
        )}
      </section>
    );
  }

  const mayAdd = access.may_add;
  const ordered = [...granted.filter((t) => mayAdd.includes(t)), ...mayAdd.filter((t) => !granted.includes(t))];
  const fixed = access.teams.map((t) => t.name).filter((t) => !mayAdd.includes(t));
  const had = access.people;
  const change: ArtifactAccessChange = {
    ...(teams.length === access.teams.length && teams.every((t) => access.teams.some((x) => x.name === t)) ? {} : { teams }),
    ...(people.length === had.length && people.every((p) => had.some((h) => h.subject === p.subject && h.role === p.role)) ? {} : { people: people.map((p) => ({ subject: p.subject, role: p.role })) }),
    ...(organisation === access.organisation ? {} : { organisation }),
  };
  const changed = Object.keys(change).length > 0;
  const name = (p: { subject: string; display_name?: string | null }): string => p.display_name || p.subject;
  const names = new Map(people.map((p) => [p.subject, name(p)] as const));

  const save = (): void => {
    setBusy(true);
    setError(null);
    setSaid(null);
    api.setAccess(a.id, change).then(
      (answer) => {
        setBusy(false);
        if (accessWaiting(answer)) {
          setSaid(`Not changed yet: ${answer.reason}.`);
          take(access);
          return;
        }
        notify(`Saved: ${accessChanges(access, change, names)}.`);
        take(answer);
        reload();
      },
      (e: unknown) => {
        setBusy(false);
        setError(e);
      },
    );
  };

  return (
    <section aria-label="Who reads it">
      <Region>Who reads it</Region>
      <p className="lead">
        It is {artifactAccessWords(access)}. A new version keeps who reads it, and changing it here makes no version.
      </p>
      <form
        className="edit"
        aria-label="Change who reads it"
        onSubmit={(e) => {
          e.preventDefault();
          save();
        }}
      >
        <fieldset className="teams" disabled={busy}>
          <legend>Teams</legend>
          {ordered.map((t) => (
            <label key={t} className="inline">
              <input type="checkbox" checked={teams.includes(t)} onChange={(e) => setTeams((now) => (e.target.checked ? [...now, t] : now.filter((x) => x !== t)))} /> The {t} team
              {granted.includes(t) && profile && <span className="hint"> · granted {profile}, which its session ran on</span>}
            </label>
          ))}
          {fixed.map((t) => (
            <label key={t} className="inline">
              <input type="checkbox" checked disabled /> The {t} team
              <span className="hint"> · shown as it is: you are not in it and {profile ? `${profile} is not granted to it` : "no session's profile grants it"}, so it is not yours to change here</span>
            </label>
          ))}
          {ordered.length === 0 && fixed.length === 0 && <p className="note">No team of yours is known here.</p>}
        </fieldset>
        {(organisationAllowed || organisation) && (
          <label className="inline">
            <input type="checkbox" checked={organisation} disabled={busy} onChange={(e) => setOrganisation(e.target.checked)} /> The whole organisation: anyone who can sign in to this plane
          </label>
        )}
        <fieldset disabled={busy}>
          <legend>People</legend>
          {people.length === 0 ? (
            <p className="note">Nobody by name.</p>
          ) : (
            <ul className="artifact-people" aria-label="Shared with">
              {people.map((p) => (
                <li key={p.subject}>
                  <b>{name(p)}</b>{" "}
                  <select aria-label={`What ${name(p)} may do`} value={p.role} onChange={(e) => setPeople((now) => now.map((x) => (x.subject === p.subject ? { ...x, role: e.target.value as ArtifactShareRole } : x)))}>
                    <option value="view">{ROLE.view}</option>
                    <option value="comment">{ROLE.comment}</option>
                    <option value="edit">{ROLE.edit}</option>
                  </select>{" "}
                  <button type="button" aria-label={`Remove ${name(p)}`} onClick={() => setPeople((now) => now.filter((x) => x.subject !== p.subject))}>
                    Remove
                  </button>
                </li>
              ))}
            </ul>
          )}
          <Field label="Add somebody" hint="People who share a team with you, and those its session's profile covers.">
            {(p) => <input {...p} value={query} placeholder="A name or an email" onChange={(e) => setQuery(e.target.value)} />}
          </Field>
          <Field label="They may">
            {(p) => (
              <select {...p} value={role} onChange={(e) => setRole(e.target.value as ArtifactShareRole)}>
                <option value="view">{ROLE.view}</option>
                <option value="comment">{ROLE.comment}</option>
                <option value="edit">{ROLE.edit}</option>
              </select>
            )}
          </Field>
          {found.length > 0 && (
            <ul className="artifact-people" aria-label="People found">
              {found.map((p) => (
                <li key={p.subject}>
                  <button
                    type="button"
                    onClick={() => {
                      setPeople((now) => [...now, { subject: p.subject, display_name: p.display_name ?? null, role }]);
                      setQuery("");
                    }}
                  >
                    Add {name(p)}
                    {p.email && p.email !== name(p) ? ` · ${p.email}` : ""}
                  </button>
                </li>
              ))}
            </ul>
          )}
          {query.trim() !== "" && found.length === 0 && <p className="hint">Nobody you can share with has a name that starts with that.</p>}
        </fieldset>
        {changed && <p className="hint">Not saved yet: {accessChanges(access, change, names)}.</p>}
        {error !== null && (
          <p className="field-error" role="alert">
            Not saved: {describeError(error)}
          </p>
        )}
        {said && (
          <p className="note" role="status">
            {said}
          </p>
        )}
        <div className="actions">
          <button type="submit" className="primary" disabled={busy || !changed}>
            Save who reads it
          </button>
          {changed && (
            <button type="button" disabled={busy} onClick={() => take(access)}>
              Undo changes
            </button>
          )}
        </div>
      </form>
    </section>
  );
}
