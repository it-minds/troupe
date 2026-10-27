// What the troupe remembers for the person (troupe #55), in their own app: the memory every
// new session of theirs starts with, as entries, one per `## Topic` of a level's document.
// The organisation's is the lowest level, a team's is closer, the person's own the closest;
// on a topic the closest level's entry replaces the lower ones.
//
// "In effect for you" is what a new session in one of their teams starts knowing: the
// winner on each topic, with what it replaces struck through. Each level is listed on its
// own; the person changes their own here (adding, editing and forgetting entries, saved as
// the whole document over the version they read, through this computer's daemon, which
// hands the new version to the sessions running here for their next turn). The levels above
// are read here and kept in the console by those who may change them.
//
// The person's own level has a Versions drawer: every version, any two side by side, a
// rollback to one, who wrote each line, where this computer's copy stands and what each
// session running here read at its last turn. An agent's `remember` landing while the view
// is open reads it again (`config.changed` for memory). Local only keeps the app off the
// plane: nothing is read from it, and the view says what this computer holds and why.

import { useCallback, useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import { besideRows, entriesText, entryWriter, inEffect, parseEntries, replacedBy, topicKey, writtenBy } from "@troupe/client";
import type { DaemonClient, EntryLevel, MemoryEntry, MemoryStatus, OwnMemory, OwnMemoryHistory } from "@troupe/client";
import { Loading, relative } from "./bits";

type View = "effect" | string;

interface Level {
  key: string;
  level: EntryLevel;
  label: string;
  short: string;
  glyph: string;
  entries: MemoryEntry[];
  editable: boolean;
}

function message(e: unknown): string {
  const data = (e as { data?: { reason?: unknown } } | null)?.data;
  if (data && typeof data.reason === "string") return data.reason;
  return e instanceof Error ? e.message : String(e);
}

const isConflict = (e: unknown): boolean => (e as { message?: unknown } | null)?.message === "conflict" || (e as { code?: unknown } | null)?.code === -32006;

/** The levels a person's sessions read, lowest first: the organisation's, each team's, their own. */
export function levelsOf(own: OwnMemory, teams: string[]): Level[] {
  const documents = own.documents ?? [];
  const organisation = documents.find((d) => d.scope === "organisation");
  const teamNames = [...new Set([...teams, ...documents.filter((d) => d.scope === "team" && d.name).map((d) => d.name!)])];
  return [
    { key: "organisation", level: { scope: "organisation", name: null }, label: "Everyone", short: "EVERYONE", glyph: "◉", entries: parseEntries(organisation?.text ?? ""), editable: false },
    ...teamNames.map((name): Level => ({
      key: `team:${name}`,
      level: { scope: "team", name },
      label: name,
      short: name.toUpperCase(),
      glyph: "◎",
      entries: parseEntries(documents.find((d) => d.scope === "team" && d.name === name)?.text ?? ""),
      editable: false,
    })),
    { key: "user", level: { scope: "user", name: null }, label: "Only you", short: "YOU", glyph: "○", entries: parseEntries(own.text), editable: true },
  ];
}

function sourceOf(level: EntryLevel, levels: Level[]): Level {
  return levels.find((l) => l.level.scope === level.scope && l.level.name === level.name) ?? levels[levels.length - 1]!;
}

/** A toast in the corner that says what a save did, gone in five seconds or at a click. */
function Toast({ text, onDone }: { text: string; onDone: () => void }): JSX.Element {
  useEffect(() => {
    const t = setTimeout(onDone, 5000);
    return () => clearTimeout(t);
  }, [text, onDone]);
  return (
    <div className="toast" role="status">
      <span className="dot" aria-hidden="true">
        ●
      </span>
      <span className="text">{text}</span>
      <button type="button" className="dismiss" aria-label="Dismiss" onClick={onDone}>
        ×
      </button>
    </div>
  );
}

export function MemoryScreen({ daemon, localOnly, teams }: { daemon: DaemonClient | null; localOnly: boolean; teams: string[] }): JSX.Element {
  const [own, setOwn] = useState<OwnMemory | null>(null);
  const [why, setWhy] = useState<string | null>(null);
  const [status, setStatus] = useState<MemoryStatus | null>(null);
  const [view, setView] = useState<View>("effect");
  const [team, setTeam] = useState<string | null>(teams[0] ?? null);
  const [toast, setToast] = useState<string | null>(null);
  const [asked, setAsked] = useState(0);

  const read = useCallback(() => setAsked((n) => n + 1), []);

  useEffect(() => {
    if (!daemon) return;
    let live = true;
    daemon.memoryStatus().then(
      (s) => live && setStatus(s),
      () => undefined,
    );
    if (!localOnly) {
      daemon.ownMemory({ blame: true }).then(
        (o) => {
          if (!live) return;
          setWhy(null);
          setOwn(o);
        },
        (e: unknown) => live && setWhy(message(e)),
      );
    }
    return () => {
      live = false;
    };
  }, [daemon, localOnly, asked]);

  // A save from elsewhere, or an agent's entry, reaches this computer's copy: read it again.
  useEffect(() => {
    if (!daemon) return;
    return daemon.onConfigChanged((changed) => {
      if ((changed as { scope?: unknown }).scope === "memory") read();
    });
  }, [daemon, read]);

  const levels = own ? levelsOf(own, teams) : [];
  const editable = levels.filter((l) => l.editable).map((l) => l.label);
  const head = (
    <header className="memory-head">
      <div className="lede">
        <span className="screen">What the troupe remembers</span>
        <h1>Memory</h1>
        <p className="muted">Notes every new session starts with. When two levels disagree, the closer one wins: yours over your team's, your team's over your organisation's.</p>
      </div>
      <div className="can-change micro">
        YOU CAN CHANGE
        <br />
        <span>{localOnly ? "nothing while Local only is on" : editable.join(" · ") || "Only you"}</span>
      </div>
    </header>
  );

  if (localOnly || !daemon) {
    const mine = status?.documents.find((d) => d.scope === "user");
    return (
      <div className="memory-screen">
        {head}
        <p className="note">
          {daemon
            ? "Local only: the plane is not asked. Your memory is kept on your organisation's plane, so it is read only here, and changed when Local only is off."
            : "This computer's daemon is not connected, and your memory is read through it."}
        </p>
        {status && (
          <p className="muted">
            {mine ? `This computer holds version ${mine.version} of your memory` : "This computer holds no copy of your memory"}
            {status.fetched_at ? `, fetched ${relative(Date.parse(status.fetched_at))}` : ""}. {status.reason ?? ""}
          </p>
        )}
      </div>
    );
  }
  if (why) return <div className="memory-screen">{head}<p className="note">Your memory: {why}</p></div>;
  if (!own) return <div className="memory-screen">{head}<Loading what="Reading your memory…" /></div>;

  const teamLevels = levels.filter((l) => l.level.scope === "team");
  const chosenTeam = teamLevels.find((l) => l.level.name === team) ?? teamLevels[0] ?? null;
  const chain = levels.filter((l) => l.level.scope !== "team" || l === chosenTeam);
  const effect = inEffect(chain.map((l) => ({ level: l.level, entries: l.entries })));
  const current = levels.find((l) => l.key === view) ?? null;

  return (
    <div className="memory-screen">
      {head}
      <nav className="levels" aria-label="Memory level">
        <button type="button" className="level in-effect" aria-pressed={view === "effect"} onClick={() => setView("effect")}>
          In effect for you
        </button>
        <span className="rule" aria-hidden="true" />
        {levels.map((l, i) => (
          <span key={l.key} className="level-slot">
            {i > 0 && (
              <span className="sep micro" aria-hidden="true">
                {l.level.scope === "team" && levels[i - 1]!.level.scope === "team" ? "·" : "‹"}
              </span>
            )}
            <button type="button" className={`level is-${l.level.scope}`} aria-pressed={view === l.key} onClick={() => setView(l.key)}>
              <span className="glyph" aria-hidden="true">
                {l.glyph}
              </span>
              <span>{l.label}</span>
              <span className="n micro">{l.entries.length}</span>
              {!l.editable && (
                <span className="n micro" aria-label="read only">
                  · READ
                </span>
              )}
            </button>
          </span>
        ))}
        <span className="order micro">LOWEST ‹ CLOSEST</span>
      </nav>

      {view === "effect" && (
        <section className="in-effect-view" aria-label="In effect for you">
          <div className="team-pick">
            <span className="muted">A new session{chosenTeam ? " in" : ""}</span>
            {teamLevels.length > 0 && (
              <span role="group" aria-label="Team" className="picker">
                {teamLevels.map((t) => (
                  <button key={t.key} type="button" aria-pressed={t === chosenTeam} onClick={() => setTeam(t.level.name)}>
                    {t.label}
                  </button>
                ))}
              </span>
            )}
            <span className="muted">starts knowing this:</span>
          </div>
          {effect.length === 0 ? (
            <div className="empty">
              <p className="title">Nothing yet</p>
              <p className="muted">No level has a memory. Add one of your own under Only you.</p>
            </div>
          ) : (
            <ol className="entries">
              {effect.map((e, i) => {
                const from = sourceOf(e.from, levels);
                return (
                  <li key={`${e.topic}-${i}`} className={`entry is-${e.from.scope}`}>
                    <div className="entry-body">
                      <div className="entry-top">
                        <span className="topic">{e.topic || "No topic"}</span>
                        <span className={`from micro is-${e.from.scope}`}>
                          {from.glyph} FROM {from.short}
                        </span>
                      </div>
                      <p>{e.body}</p>
                    </div>
                    {e.replaces.map((u, j) => (
                      <div key={j} className="replaces">
                        <span className="micro">REPLACES {sourceOf(u.from, levels).short}</span>
                        <s>{u.body}</s>
                      </div>
                    ))}
                  </li>
                );
              })}
            </ol>
          )}
        </section>
      )}

      {current && (
        <LevelView
          key={current.key}
          daemon={daemon}
          own={own}
          level={current}
          levels={levels}
          status={status}
          onSaved={(saved, said) => {
            setOwn({ ...saved, ...(own.documents ? { documents: own.documents } : {}) });
            setToast(said);
            read();
          }}
          onReload={read}
        />
      )}
      {toast && <Toast text={toast} onDone={() => setToast(null)} />}
    </div>
  );
}

const NOTES: Record<EntryLevel["scope"], { note: string; lock: string; empty: string; emptyBody: string }> = {
  organisation: {
    note: "The baseline. Every session in every team starts with these unless a team or a person says otherwise.",
    lock: "Platform administrators keep your organisation's memory, in the Troupe console. Ask one of them if something here is wrong or out of date.",
    empty: "No organisation memory yet",
    emptyBody: "Sessions start with your teams' memory and your own.",
  },
  team: {
    note: "Applies to every session of this team. Replaces your organisation's memory on the same topic.",
    lock: "This team's administrators keep its memory, in the Troupe console.",
    empty: "This team has no memory of its own",
    emptyBody: "Sessions in this team use your organisation's memory as it is.",
  },
  user: {
    note: "Applies to every session you start, in any team. Nobody else can see these, not even administrators.",
    lock: "",
    empty: "Nothing personal yet",
    emptyBody: "Tell the troupe how you like to work: length of answers, language, what to skip. It applies in every team.",
  },
};

type Editing = { index: number | null; topic: string; body: string } | null;

/** One level's entries: read, or for the person's own, added to, edited and forgotten. */
function LevelView({
  daemon,
  own,
  level,
  levels,
  status,
  onSaved,
  onReload,
}: {
  daemon: DaemonClient;
  own: OwnMemory;
  level: Level;
  levels: Level[];
  status: MemoryStatus | null;
  onSaved: (saved: OwnMemory, said: string) => void;
  onReload: () => void;
}): JSX.Element {
  const [editing, setEditing] = useState<Editing>(null);
  const [forgetting, setForgetting] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [conflict, setConflict] = useState<OwnMemory | null>(null);
  const [versions, setVersions] = useState(false);
  const notes = NOTES[level.level.scope];
  const title = level.level.scope === "team" ? `Team ${level.label}` : level.level.scope === "organisation" ? "Everyone in your organisation" : "Only you";
  const scopeLine = level.level.scope === "user" ? "SAVES TO ONLY YOU · YOUR NEW SESSIONS IN ANY TEAM" : "";

  const save = (entries: MemoryEntry[], said: string): void => {
    setBusy(true);
    setError(null);
    daemon
      .putOwnMemory(entriesText(entries), own.version)
      .then((saved) => {
        setEditing(null);
        setForgetting(null);
        onSaved(saved.user, saved.changed ? said : "Nothing changed; nothing was saved.");
      })
      .catch(async (e: unknown) => {
        if (isConflict(e)) {
          setConflict(await daemon.ownMemory().catch(() => null));
          setError(message(e));
        } else {
          setError(message(e));
        }
      })
      .finally(() => setBusy(false));
  };

  const draftEmpty = !editing || editing.topic.trim() === "" || editing.body.trim() === "";
  let clash = "";
  if (editing && editing.topic.trim() !== "") {
    const key = topicKey(editing.topic);
    const here = level.entries.findIndex((e, i) => i !== editing.index && e.topic !== "" && topicKey(e.topic) === key);
    const lower = levels.find((l) => l.level.scope !== "user" && l.entries.some((e) => e.topic !== "" && topicKey(e.topic) === key));
    if (here >= 0) clash = `Only you already has a memory called “${level.entries[here]!.topic}”. Edit that one instead, or pick another topic.`;
    else if (lower) clash = `This will replace ${lower.level.scope === "team" ? `team ${lower.label}'s` : "your organisation's"} “${editing.topic.trim()}” for you.`;
  }

  const commit = (): void => {
    if (!editing || draftEmpty) return;
    const entry = { topic: editing.topic.trim(), body: editing.body.trim() };
    const entries = editing.index === null ? [...level.entries, entry] : level.entries.map((e, i) => (i === editing.index ? entry : e));
    save(entries, editing.index === null ? "Saved. New sessions start with it; the sessions running here read it at their next turn." : "Saved. New sessions start with the new version.");
  };

  const form = (label: string): JSX.Element => (
    <div className="entry-form" aria-label={label}>
      <div className="fields">
        <label className="field">
          <span className="micro">TOPIC</span>
          <input value={editing?.topic ?? ""} onChange={(e) => setEditing((d) => d && { ...d, topic: e.target.value })} placeholder="Tone, Prices, Client names…" />
        </label>
        <label className="field">
          <span className="micro">WHAT TO REMEMBER</span>
          <textarea value={editing?.body ?? ""} onChange={(e) => setEditing((d) => d && { ...d, body: e.target.value })} rows={3} placeholder="Write it the way you would tell a new colleague." />
        </label>
        {clash && <p className="clash">{clash}</p>}
      </div>
      <div className="form-actions">
        <button type="button" className="primary" disabled={draftEmpty || busy} onClick={commit}>
          {busy ? "Saving…" : "Save"}
        </button>
        <button type="button" disabled={busy} onClick={() => setEditing(null)}>
          Cancel
        </button>
        <span className="micro scope">{scopeLine}</span>
      </div>
    </div>
  );

  return (
    <section className="level-view" aria-label={title}>
      <div className="level-head">
        <div>
          <h2>{title}</h2>
          <p className="muted">{notes.note}</p>
        </div>
        <div className="level-actions">
          {level.editable && !(editing && editing.index === null) && (
            <button type="button" className="primary" onClick={() => setEditing({ index: null, topic: "", body: "" })}>
              Add a memory
            </button>
          )}
          {level.level.scope === "user" && (
            <button type="button" aria-expanded={versions} onClick={() => setVersions((v) => !v)}>
              Versions
            </button>
          )}
        </div>
      </div>
      {!level.editable && (
        <p className="read-only">
          <span className="micro">READ ONLY</span> {notes.lock}
        </p>
      )}
      {error && <p className="note error">{error}</p>}
      {conflict && (
        <div className="conflict" role="alert">
          <p>Version {conflict.version} was saved somewhere else since you read it. It says:</p>
          <pre className="mono">{conflict.text || "(nothing)"}</pre>
          <button
            type="button"
            onClick={() => {
              setConflict(null);
              setError(null);
              setEditing(null);
              onReload();
            }}
          >
            Reload version {conflict.version}
          </button>
        </div>
      )}
      {versions && level.level.scope === "user" && <Versions daemon={daemon} own={own} status={status} onRolledBack={(saved, said) => onSaved(saved, said)} />}
      {editing && editing.index === null && form("New memory")}
      {level.entries.length === 0 && !editing ? (
        <div className="empty">
          <p className="title">{notes.empty}</p>
          <p className="muted">{notes.emptyBody}</p>
        </div>
      ) : (
        <ol className="entries">
          {level.entries.map((entry, i) => {
            const closer = replacedBy(level.level, entry, levels.map((l) => ({ level: l.level, entries: l.entries })));
            const badge =
              closer.length === 0
                ? null
                : level.level.scope === "organisation"
                  ? `REPLACED IN ${closer.map((c) => sourceOf(c, levels).short).join(", ")}`
                  : closer.some((c) => c.scope === "user")
                    ? "REPLACED FOR YOU BY YOUR OWN"
                    : null;
            const writer = level.level.scope === "user" ? entryWriter(entry, own.lines) : null;
            const by = writer ? (writer.agent ? `${writer.agent.replace(/^agent:/, "").toUpperCase()} IN A SESSION` : (writer.by ?? "").toUpperCase()) : "";
            if (editing?.index === i) return <li key={i} className={`entry is-${level.level.scope} editing`}>{form("Edit memory")}</li>;
            return (
              <li key={i} className={`entry is-${level.level.scope}`}>
                <div className="entry-body">
                  <div className="entry-top">
                    <span className="topic">{entry.topic || "No topic"}</span>
                    {badge && <span className="replaced micro">{badge}</span>}
                  </div>
                  <p>{entry.body}</p>
                  <div className="entry-meta">
                    {writer && (
                      <span className="micro">
                        {by} · {writer.at ? relative(Date.parse(writer.at)).toUpperCase() : `VERSION ${writer.version}`}
                      </span>
                    )}
                    {level.editable && (
                      <span className="entry-actions">
                        <button
                          type="button"
                          onClick={() => {
                            setForgetting(null);
                            setEditing({ index: i, topic: entry.topic, body: entry.body });
                          }}
                        >
                          Edit
                        </button>
                        <button type="button" onClick={() => setForgetting(i)}>
                          Forget
                        </button>
                      </span>
                    )}
                  </div>
                </div>
                {forgetting === i && (
                  <div className="forget" role="alertdialog" aria-label="Forget this memory">
                    <p>Forget “{entry.topic || "this memory"}”? New sessions stop starting with it. Sessions already running keep it until their next turn.</p>
                    <button
                      type="button"
                      className="danger"
                      disabled={busy}
                      onClick={() => save(level.entries.filter((_, j) => j !== i), `Forgotten. New sessions will not start with “${entry.topic || "it"}”.`)}
                    >
                      Forget
                    </button>
                    <button type="button" onClick={() => setForgetting(null)}>
                      Keep it
                    </button>
                  </div>
                )}
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}

/**
 * The person's own memory's history: every version, two side by side (the older on the
 * left), a rollback to one as the next version, who wrote each line, and where this
 * computer stands: its copy against the plane's, and what each session running here read.
 */
function Versions({
  daemon,
  own,
  status,
  onRolledBack,
}: {
  daemon: DaemonClient;
  own: OwnMemory;
  status: MemoryStatus | null;
  onRolledBack: (saved: OwnMemory, said: string) => void;
}): JSX.Element {
  const [history, setHistory] = useState<OwnMemoryHistory | null>(null);
  const [right, setRight] = useState<number | null>(null);
  const [left, setLeft] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [blame, setBlame] = useState(false);
  const [busy, setBusy] = useState(false);
  const first = useRef(true);

  useEffect(() => {
    let live = true;
    const params = right === null ? {} : left === null ? { version: right } : { version: right, against: left };
    daemon.ownMemoryHistory(params).then(
      (h) => {
        if (!live) return;
        setHistory(h);
        if (first.current) {
          first.current = false;
          setRight(h.version);
          setLeft(h.against);
        }
      },
      (e: unknown) => live && setError(message(e)),
    );
    return () => {
      live = false;
    };
  }, [daemon, right, left, own.version]);

  const rollback = (to: number): void => {
    setBusy(true);
    setError(null);
    daemon
      .rollbackOwnMemory(to, own.version)
      .then((saved) => onRolledBack(saved.user, `Rolled back: version ${to}'s text is version ${saved.user.version} now.`))
      .catch((e: unknown) => setError(message(e)))
      .finally(() => setBusy(false));
  };

  const mine = (docs: Array<{ scope: string; version: number }>): number | null => docs.find((d) => d.scope === "user")?.version ?? null;
  const pick = (value: string): number | null => (value === "" ? null : Number(value));

  return (
    <div className="versions-drawer" aria-label="Versions of your memory">
      {status && (
        <p className="standing muted">
          {status.current === null
            ? `This computer holds version ${mine(status.documents) ?? 0} of your memory; ${status.reason ?? "the plane was not asked"}.`
            : status.current
              ? `This computer's copy is current: version ${mine(status.documents) ?? 0} is the one in force.`
              : `This computer's copy is behind: it holds version ${mine(status.documents) ?? 0}, and version ${mine(status.in_force ?? []) ?? 0} is in force.`}
        </p>
      )}
      {status && status.sessions.length > 0 && (
        <ul className="session-reads">
          {status.sessions.map((s) => (
            <li key={s.session_id}>
              <span className="mono">{s.session_id}</span> read {mine(s.documents) === null ? "none of your memory" : `version ${mine(s.documents)}`} at its last turn, {relative(Date.parse(s.turn_at))}:{" "}
              <span className={s.current ? "current" : "behind"}>{s.current ? "current" : "behind"}</span>
            </li>
          ))}
        </ul>
      )}
      {error && <p className="note error">{error}</p>}
      {!history ? (
        <Loading what="Reading its versions…" />
      ) : history.versions.length === 0 ? (
        <p className="muted">Nothing has been saved yet.</p>
      ) : (
        <>
          <ol className="version-list">
            {history.versions.map((v) => (
              <li key={v.version}>
                <span className="n">v{v.version}</span>
                <span>{v.changed_by ?? ""}</span>
                <span className="micro" title={v.changed_at}>
                  {relative(Date.parse(v.changed_at))}
                </span>
                {v.version !== own.version && (
                  <button type="button" className="link" disabled={busy} onClick={() => rollback(v.version)}>
                    Roll back to version {v.version}
                  </button>
                )}
              </li>
            ))}
          </ol>
          <div className="beside-pick">
            <label>
              <span className="micro">LEFT</span>
              <select aria-label="The older version" value={left ?? ""} onChange={(e) => setLeft(pick(e.target.value))}>
                <option value="">Nothing</option>
                {history.versions.map((v) => (
                  <option key={v.version} value={v.version}>
                    Version {v.version}
                  </option>
                ))}
              </select>
            </label>
            <label>
              <span className="micro">RIGHT</span>
              <select aria-label="The newer version" value={right ?? ""} onChange={(e) => setRight(pick(e.target.value))}>
                {history.versions.map((v) => (
                  <option key={v.version} value={v.version}>
                    Version {v.version}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <table className="side-by-side mono" aria-label={`Version ${history.against ?? 0} beside version ${history.version ?? 0}`}>
            <thead>
              <tr>
                <th scope="col">Version {history.against ?? 0}</th>
                <th scope="col">Version {history.version ?? 0}</th>
              </tr>
            </thead>
            <tbody>
              {besideRows(history.diff).map((r, i) => (
                <tr key={i}>
                  <td className={r.left === null ? "empty" : r.changed ? "del" : "ctx"}>
                    {r.left !== null && r.changed && <span className="visually-hidden">removed: </span>}
                    {r.left ?? ""}
                  </td>
                  <td className={r.right === null ? "empty" : r.changed ? "add" : "ctx"}>
                    {r.right !== null && r.changed && <span className="visually-hidden">added: </span>}
                    {r.right ?? ""}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
      <button type="button" className="link" aria-expanded={blame} onClick={() => setBlame((b) => !b)}>
        {blame ? "Hide who wrote each line" : "Who wrote each line"}
      </button>
      {blame && (
        <table className="blame-lines mono" aria-label="Who wrote each line of your memory">
          <tbody>
            {(own.lines ?? []).map((l, i) => (
              <tr key={i}>
                <th scope="row" title={l.at ?? undefined}>
                  {writtenBy(l)}
                </th>
                <td>{l.text}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
