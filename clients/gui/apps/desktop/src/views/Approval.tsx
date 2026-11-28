// The approval panel. The core loop, and the only amber on the screen.
//
// It never takes over: no modal, no dimming, no countdown, no sound. It wins by
// position (sticky at the bottom of the conversation, where the thumb already is),
// colour (the reserved amber), light (the footlight, which nothing else has), and
// language — the headline is a question in four words.
//
// When somebody else answers first, the panel does not vanish. Disappearing would
// leave the reader wondering whether they pressed something; instead it is replaced in
// place by a calm record that names who decided and says nothing is waiting on them.

import { useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import { BRIEF_PARTS, artifactAccessWords, offeredTeams, publishAnswer, callConsequence as consequence, callEvidence, callHeadline as headline, callScopedLabel as scopedLabel, decisionWords, errorText, ruleScope } from "@troupe/client";
import type { ApprovalDecision, DelegationGate, Entry, GateAnswer, PublicationGate } from "@troupe/client";
import { Pill } from "./bits";
import { Mask } from "./brand";

export type Decision = ApprovalDecision;
/** Where an Always allow rule is written: the workspace's own file or the person's config.yaml. */
type RuleScope = "workspace" | "everywhere";
type Approval = Extract<Entry, { kind: "approval" }>;

/**
 * Who a person may have read a new artifact, as the plane names it: their teams, and whether
 * they may publish to the whole organisation (false where only a platform admin may and they
 * are not one).
 */
export interface Audiences {
  teams: string[];
  organisation: boolean;
}

/** A brief's parts by the names a person reads them by (troupe Decision 847). */
const PART_NAMES: Record<string, string> = {
  goal: "Goal",
  context: "Context",
  constraints: "Constraints",
  deliverable: "Deliverable",
  do_not: "Do not",
};

// The headline, the consequence and the scoped answer's label are the client's words, which
// the console's relayed approval says too.

/** The evidence, rendered rather than dumped. */
function Evidence({ entry }: { entry: Approval }): JSX.Element | null {
  const { command, cwd: named, path } = callEvidence(entry.args);
  // The folder the call acts in: its own, else the one the server said (troupe #932).
  const cwd = named ?? entry.cwd ?? null;

  if (command) {
    return (
      <div className="evidence">
        <div className="command">{command}</div>
        {cwd && <p className="also">In {cwd}.</p>}
      </div>
    );
  }
  if (path) {
    return (
      <div className="evidence">
        <div className="command">{path}</div>
      </div>
    );
  }
  return (
    <div className="evidence">
      <pre>{JSON.stringify(entry.args, null, 2)}</pre>
    </div>
  );
}

export function ApprovalPanel({
  entry,
  canAnswer,
  others,
  onAnswer,
  onDefinition,
  onceOnly = false,
  alwaysAllow = false,
  audiences,
}: {
  entry: Approval;
  /** False on a read-only session: the buttons are absent, not disabled. */
  canAnswer: boolean;
  /** Other people who could answer this too, by display name. */
  others: string[];
  onAnswer: (decision: Decision, answer?: GateAnswer) => Promise<void>;
  /** Opens a delegation's agent in the agents manager, where there is one to open. */
  onDefinition?: ((agent: string) => void) | undefined;
  /**
   * A laptop's session steered from here, through the plane: a call is allowed or denied
   * once, and allowing it for the rest of the session is the laptop's person's to do there.
   */
  onceOnly?: boolean;
  /**
   * Whether the server takes `allow_always` (it named `approval_allow_always` at
   * `initialize`): a lasting per-tool rule for the person, written from the approval. A
   * server that does not (a pod, whose rules are its profile's) is not offered it.
   */
  alwaysAllow?: boolean;
  /** Who may read a new artifact: the person's teams and the organisation switch, once the plane said them. */
  audiences?: Audiences | null | undefined;
}): JSX.Element {
  // An agent's publication: a new one asks who reads it and whose it is; a new version says who reads it.
  if (entry.publication && entry.decision === undefined) {
    return <PublishPanel entry={entry} publication={entry.publication} audiences={audiences ?? null} canAnswer={canAnswer} others={others} onAnswer={onAnswer} onceOnly={onceOnly} />;
  }
  // A delegation a person asked to see first has five answers, not three.
  if (entry.delegation && entry.decision === undefined) {
    return (
      <DelegationPanel
        gate={entry.delegation}
        canAnswer={canAnswer}
        others={others}
        onAnswer={onAnswer}
        onDefinition={onDefinition}
        onceOnly={onceOnly}
      />
    );
  }
  return <ToolApproval entry={entry} canAnswer={canAnswer} others={others} onAnswer={onAnswer} onceOnly={onceOnly} alwaysAllow={alwaysAllow} />;
}

function ToolApproval({
  entry,
  canAnswer,
  others,
  onAnswer,
  onceOnly,
  alwaysAllow,
}: {
  entry: Approval;
  canAnswer: boolean;
  others: string[];
  onAnswer: (decision: Decision, answer?: GateAnswer) => Promise<void>;
  onceOnly: boolean;
  alwaysAllow: boolean;
}): JSX.Element {
  const [busy, setBusy] = useState<Decision | null>(null);
  const [error, setError] = useState<string | null>(null);
  const allow = useRef<HTMLButtonElement>(null);

  const answered = entry.decision !== undefined;

  // A and D answer, but never while somebody is typing, and never by moving focus.
  useEffect(() => {
    if (answered || !canAnswer) return;
    const onKey = (e: KeyboardEvent): void => {
      const target = e.target as HTMLElement | null;
      if (target && /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName)) return;
      if (target?.isContentEditable) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === "a" || e.key === "A") void answer("allow");
      if (e.key === "d" || e.key === "D") void answer("deny");
    };
    globalThis.addEventListener("keydown", onKey);
    return () => globalThis.removeEventListener("keydown", onKey);
  });

  // Always allow asks where the rule applies, once, before it is written: this workspace
  // (the default) or every session on this computer.
  const [asking, setAsking] = useState(false);

  const answer = async (decision: Decision, scope?: RuleScope): Promise<void> => {
    if (busy) return;
    setBusy(decision);
    setError(null);
    try {
      // A lasting rule is kept in the person's own file: the workspace's config.local.yaml, or
      // their config.yaml, which every session on this computer reads. The daemon writes it,
      // and refuses where only the platform's rules count, or in a workspace not trusted.
      await (decision === "allow_always" ? onAnswer(decision, { scope: scope ?? "workspace" }) : onAnswer(decision));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(null);
    }
  };

  // Answered, by whoever got there first. The amber goes, the panel stays.
  if (answered) {
    const mine = entry.resolvedBy === undefined;
    return (
      <section className="approval answered" aria-live="assertive">
        <header>
          <Pill status={entry.decision === "deny" ? "denied" : "allowed"} />
          <h2>{headline(entry.tool)}</h2>
        </header>
        <p className="consequence">
          {entry.decision === "deny"
            ? `Denied${mine ? " by you" : ` by ${entry.resolvedBy}`} — nothing was changed.`
            : `Allowed${mine ? " by you" : ` by ${entry.resolvedBy}`}. Nothing is waiting for you now.`}
        </p>
      </section>
    );
  }

  return (
    <section className="approval">
      {/* The mask, lit and pulsing, then the word, then the question: the comp's header row. */}
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>{headline(entry.tool)}</h2>
      </header>
      {/* What it is about scrolls; the header and the answers stay on the screen. */}
      <div className="panel-body">
        <p className="consequence">{consequence(entry.tool)}</p>
        {/* A per-tool rule of the configuration asked (troupe #658): which, and whose. */}
        {entry.rule && (
          <p className="also asked-by">
            Asked by the rule <code>ask {entry.rule.rule}</code>, from {ruleScope(entry.rule)}
            {entry.rule.source ? ` (${entry.rule.source})` : ""}. Every call it matches asks, whatever was allowed for this session.
          </p>
        )}
        <Evidence entry={entry} />
        {others.length > 0 && (
          <p className="also">
            {others.length === 1 ? `${others[0]} can answer this too.` : `${others.slice(0, -1).join(", ")} and ${others.at(-1)} can answer this too.`}{" "}
            The first answer counts.
          </p>
        )}
      </div>
      {error && <p className="also error">{error}</p>}

      {canAnswer ? (
        <div className="answers">
          <button ref={allow} className="allow" onClick={() => void answer("allow")} disabled={busy !== null}>
            {busy === "allow" ? "Allowing…" : "Allow once"}
          </button>
          {!onceOnly && (
            <button className="scoped" onClick={() => void answer("allow_session")} disabled={busy !== null}>
              {scopedLabel(entry.tool)}
            </button>
          )}
          {/* A lasting rule from the approval is the server's `allow_always` (troupe #920): a
              daemon names it at `initialize`. A pod does not, its rules being its worker
              profile's, and there the answer is not drawn: allowing for the session is. */}
          {!onceOnly && alwaysAllow && (
            <button
              className="always"
              onClick={() => setAsking((open) => !open)}
              disabled={busy !== null}
              aria-expanded={asking}
              title={`A rule of your own: every call to ${entry.tool} runs unasked from now on, in this workspace or everywhere`}
            >
              {busy === "allow_always" ? "Allowing…" : `Always allow ${entry.tool}`}
            </button>
          )}
          <button className="deny" onClick={() => void answer("deny")} disabled={busy !== null}>
            {busy === "deny" ? "Denying…" : "Deny"}
          </button>
          {asking && !onceOnly && alwaysAllow && (
            <div className="always-scope" role="group" aria-label={`Where to always allow ${entry.tool}`}>
              <span className="where">Always allow {entry.tool} where?</span>
              <button
                autoFocus
                onClick={() => void answer("allow_always", "workspace")}
                disabled={busy !== null}
                title="A rule in this workspace's .troupe/config.local.yaml, which is yours and not the repository's"
              >
                This workspace
              </button>
              <button
                onClick={() => void answer("allow_always", "everywhere")}
                disabled={busy !== null}
                title="A rule in your own config.yaml, which every session on this computer reads"
              >
                Everywhere
              </button>
            </div>
          )}
        </div>
      ) : (
        <p className="also">You can read this session but not answer for it.</p>
      )}
    </section>
  );
}

/**
 * A delegation a person asked to see before it starts (troupe Decision 850): the agent and
 * a way to its definition, the tools and permissions the subagent will hold, its depth and
 * budget share, and the brief's five parts. The five answers: run it; edit a part in place
 * (held to the brief's shape: a part left empty is refused); send the same brief to
 * another subagent; deny it, with a word back the agent that delegated reads as the
 * answer; or let that agent run unasked for the rest of the session. The definition is
 * linked, never edited here: an edit for one run would be a fork nobody finds again.
 */
function DelegationPanel({
  gate,
  canAnswer,
  others,
  onAnswer,
  onDefinition,
  onceOnly,
}: {
  gate: DelegationGate;
  canAnswer: boolean;
  others: string[];
  onAnswer: (decision: Decision, answer?: GateAnswer) => Promise<void>;
  onDefinition?: ((agent: string) => void) | undefined;
  onceOnly: boolean;
}): JSX.Element {
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [agent, setAgent] = useState(gate.agent);
  const [denying, setDenying] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState<Decision | null>(null);
  const [error, setError] = useState<string | null>(null);

  const answer = (): GateAnswer => ({
    ...(agent !== gate.agent ? { agent } : {}),
    ...(Object.keys(edits).length > 0 ? { brief: edits } : {}),
  });

  const send = async (decision: Decision, given: GateAnswer): Promise<void> => {
    if (busy) return;
    setBusy(decision);
    setError(null);
    try {
      await onAnswer(decision, given);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(null);
    }
  };

  const keep = (part: string): void => {
    const text = draft.trim();
    if (text === "") {
      setError("A part of the brief cannot be empty: write none where it has nothing.");
      return;
    }
    setError(null);
    setEdits((now) => {
      const next = { ...now };
      if (text === gate.brief[part]) delete next[part];
      else next[part] = text;
      return next;
    });
    setEditing(null);
  };

  const share = gate.budgetShare === null ? null : `${Math.round(gate.budgetShare * 100)}% of the budget`;
  const switched = agent !== gate.agent ? gate.agents.find((a) => a.name === agent) : undefined;

  return (
    <section className="approval delegation" aria-label={`Delegation to ${agent}`}>
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>Hand this to {agent}?</h2>
      </header>
      <div className="panel-body">
        <p className="consequence">
          The session wants a subagent to do this. Nothing starts until you answer, and what you change here is what it is given.
        </p>

        <dl className="facts gate">
          <dt>Agent</dt>
          <dd>
            {gate.agent}
            {gate.definition.description ? ` — ${gate.definition.description}` : ""}{" "}
            {onDefinition ? (
              <button type="button" className="link" onClick={() => onDefinition(gate.agent)}>
                Open its definition
              </button>
            ) : (
              <span className="muted">{[gate.definition.layer, gate.definition.path].filter(Boolean).join(" ")}</span>
            )}
          </dd>
          {switched && (
            <>
              <dt>Sent to</dt>
              <dd>
                {switched.name}
                {switched.description ? ` — ${switched.description}` : ""}, with its own tools and budget
              </dd>
            </>
          )}
          <dt>Depth</dt>
          <dd>
            {gate.depth ?? "?"} of {gate.maxDepth ?? "?"}
          </dd>
          {share && (
            <>
              <dt>Budget</dt>
              <dd>{share}</dd>
            </>
          )}
          <dt>Tools</dt>
          <dd>{gate.tools.length > 0 ? gate.tools.map((t) => `${t.name} ${t.permission}`).join(", ") : "its own"}</dd>
        </dl>

        <dl className="facts wide parts brief" aria-label="The brief">
          {BRIEF_PARTS.map((part) => {
            const text = edits[part] ?? gate.brief[part] ?? "";
            const edited = edits[part] !== undefined;
            return (
              <div key={part} className="gate-part">
                <dt>
                  {PART_NAMES[part]}
                  {edited ? " · edited" : ""}
                </dt>
                <dd>
                  {editing === part ? (
                    <form
                      className="answers"
                      onSubmit={(e) => {
                        e.preventDefault();
                        keep(part);
                      }}
                    >
                      <textarea value={draft} onChange={(e) => setDraft(e.target.value)} aria-label={`Edit ${PART_NAMES[part]}`} rows={3} />
                      <button type="submit" className="deny">
                        Keep
                      </button>
                      <button type="button" className="deny" onClick={() => setEditing(null)}>
                        Back
                      </button>
                    </form>
                  ) : (
                    <>
                      <span className="gate-text">{text}</span>{" "}
                      {canAnswer && editing === null && (
                        <button
                          type="button"
                          className="link"
                          aria-label={`Edit ${PART_NAMES[part]}`}
                          onClick={() => {
                            setDraft(text);
                            setEditing(part);
                          }}
                        >
                          Edit
                        </button>
                      )}
                    </>
                  )}
                </dd>
              </div>
            );
          })}
        </dl>

        {others.length > 0 && <p className="also">{others.join(", ")} can answer this too. The first answer counts.</p>}
      </div>
      {error && <p className="also error">{error}</p>}

      {!canAnswer ? (
        <p className="also">You can read this session but not answer for it.</p>
      ) : denying ? (
        <form
          className="answers"
          onSubmit={(e) => {
            e.preventDefault();
            const word = reason.trim();
            void send("deny", word ? { reason: word } : {});
          }}
        >
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="A word back for the agent that delegated (optional)"
            aria-label="A word back"
            disabled={busy !== null}
          />
          <button type="submit" className="deny" disabled={busy !== null}>
            {busy === "deny" ? "Denying…" : "Deny"}
          </button>
          <button type="button" className="deny" onClick={() => setDenying(false)} disabled={busy !== null}>
            Back
          </button>
        </form>
      ) : (
        <div className="answers">
          <button className="allow" onClick={() => void send("allow", answer())} disabled={busy !== null || editing !== null}>
            {busy === "allow" ? "Starting…" : "Run"}
          </button>
          <button className="deny" onClick={() => setDenying(true)} disabled={busy !== null}>
            Deny…
          </button>
          <label className="also plain">
            Send to{" "}
            <select value={agent} onChange={(e) => setAgent(e.target.value)} aria-label="Send to" disabled={busy !== null}>
              {gate.agents.map((a) => (
                <option key={a.name} value={a.name}>
                  {a.name}
                </option>
              ))}
            </select>
          </label>
          {!onceOnly && (
            <button className="scoped" onClick={() => void send("allow_session", answer())} disabled={busy !== null || editing !== null}>
              {busy === "allow_session" ? "Starting…" : `Run, and let ${agent} run unasked for this session`}
            </button>
          )}
        </div>
      )}
    </section>
  );
}


/**
 * An agent's publication before it is published: what it is (its title, kind and how many
 * files) and who would read it. A new version keeps who reads the artifact, so the panel says
 * who does, in the plane's words, and Allow is offered at once: the gate never re-aims one,
 * and who reads it is changed in its Access tab. A new artifact's panel is its sharing menu:
 * the teams the plane named ticked (those granted the session's profile), the person's other
 * teams unticked, the organisation switch where the plane allows it, and whose it is. Allow
 * sends the choice; Deny sends nothing; letting the agent publish unasked for the session is
 * offered where the agent proposed an audience or for a new version, since there is
 * something to allow again.
 */
function PublishPanel({
  entry,
  publication,
  audiences,
  canAnswer,
  others,
  onAnswer,
  onceOnly,
}: {
  entry: Approval;
  publication: PublicationGate;
  audiences: Audiences | null;
  canAnswer: boolean;
  others: string[];
  onAnswer: (decision: Decision, answer?: GateAnswer) => Promise<void>;
  onceOnly: boolean;
}): JSX.Element {
  const republish = publication.id !== null;
  const [ticked, setTicked] = useState<string[]>(publication.teams ?? []);
  const [organisation, setOrganisation] = useState(publication.visibility === "organisation");
  const [owner, setOwner] = useState<"me" | "team">(publication.owner ?? "me");
  const [busy, setBusy] = useState<Decision | null>(null);
  const [error, setError] = useState<string | null>(null);
  const teams = offeredTeams(publication, audiences?.teams ?? []);
  // The organisation switch is offered where the plane lets this person publish to it, and
  // always where the agent proposed it, so the proposal is never lost.
  const mayOrganisation = audiences?.organisation !== false || publication.visibility === "organisation";

  const send = async (decision: Decision, answer: GateAnswer = {}): Promise<void> => {
    if (busy) return;
    setBusy(decision);
    setError(null);
    try {
      await onAnswer(decision, answer);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(null);
    }
  };

  const what = publication.kind === "html" ? "A page" : publication.kind === "markdown" ? "A document" : "A file";
  const files = publication.files === 1 ? "1 file" : `${publication.files} files`;
  // A new version's answer carries nothing: it keeps who reads it and whose it is.
  const answerOf: GateAnswer = republish ? {} : publishAnswer({ organisation, teams: ticked, owner });
  const toggle = (team: string): void => setTicked((now) => (now.includes(team) ? now.filter((t) => t !== team) : [...now, team]));
  const again = republish || publication.visibility !== null || (publication.teams ?? []).length > 0;

  return (
    <section className="approval publication" aria-label={`Publish ${publication.title}`}>
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>{headline(entry.tool)}</h2>
      </header>
      <div className="panel-body">
        <p className="consequence">
          {republish
            ? "The session wants to publish a new version of an artifact. It keeps who reads the artifact: nothing about that is asked here."
            : "The session wants to publish an artifact. Nothing is published until you allow it, read by whom you choose below."}
        </p>
        <dl className="facts gate">
          <dt>Title</dt>
          <dd>{publication.title}</dd>
          <dt>What</dt>
          <dd>
            {what}, {files}
          </dd>
          {publication.id && (
            <>
              <dt>Of</dt>
              <dd>{publication.id}</dd>
              <dt>Read by</dt>
              <dd>{publication.access ? `${publication.access}, as now` : "who reads it now"}</dd>
            </>
          )}
          {publication.note && (
            <>
              <dt>Note</dt>
              <dd>{publication.note}</dd>
            </>
          )}
        </dl>
        {republish ? (
          <p className="also">To change who reads it, open it in Artifacts once it is published: its Info has an Access tab.</p>
        ) : (
          <fieldset className="audience-choices" disabled={!canAnswer || busy !== null}>
            <legend>Who reads it</legend>
            <p className="also">Its owner reads it, and whoever you share it with later from its Access tab.</p>
            {teams.map((t) => (
              <label key={t} className="inline">
                <input type="checkbox" checked={ticked.includes(t)} onChange={() => toggle(t)} /> The {t} team
                {(publication.teams ?? []).includes(t) && <span className="also"> · proposed</span>}
              </label>
            ))}
            {teams.length === 0 && <p className="also">No team of yours is known here, so only you and the organisation are offered.</p>}
            {mayOrganisation && (
              <label className="inline">
                <input type="checkbox" checked={organisation} onChange={(e) => setOrganisation(e.target.checked)} /> The whole organisation
              </label>
            )}
            {!mayOrganisation && <p className="also">Only a platform admin may publish to the whole organisation here.</p>}
            <p className="also readers">{ticked.length === 0 && !organisation ? "Only you will read it." : `It will be ${artifactAccessWords({ teams: ticked, organisation })}.`}</p>
            <label className="inline">
              <input type="radio" name={`publish-owner-${entry.callId}`} checked={owner === "me" || ticked.length !== 1} onChange={() => setOwner("me")} /> Yours
            </label>
            <label className="inline">
              <input type="radio" name={`publish-owner-${entry.callId}`} checked={owner === "team" && ticked.length === 1} disabled={ticked.length !== 1} onChange={() => setOwner("team")} /> {ticked.length === 1 ? `The ${ticked[0]} team's, every member its owner` : "A team's, every member its owner (tick one team)"}
            </label>
          </fieldset>
        )}
        {others.length > 0 && <p className="also">{others.join(", ")} can answer this too. The first answer counts.</p>}
      </div>
      {error && <p className="also error">{error}</p>}
      {canAnswer ? (
        <div className="answers">
          <button className="allow" disabled={busy !== null} onClick={() => void send("allow", answerOf)}>
            {busy === "allow" ? "Publishing…" : onceOnly ? "Allow once" : "Allow"}
          </button>
          <button className="deny" disabled={busy !== null} onClick={() => void send("deny")}>
            {busy === "deny" ? "Denying…" : "Deny"}
          </button>
          {!onceOnly && again && (
            <button className="scoped" disabled={busy !== null} onClick={() => void send("allow_session", answerOf)}>
              Allow, and let it publish unasked for this session
            </button>
          )}
        </div>
      ) : (
        <p className="also">You can read this session but not answer for it.</p>
      )}
    </section>
  );
}

/** What an approval becomes in the stream once it has been answered. Never deleted. */
export function DecisionRecord({ entry, self }: { entry: Approval; self: string | undefined }): JSX.Element {
  const by = entry.resolvedBy ?? self;
  const mine = by === undefined || by === self;
  const verb = decisionWords(entry.decision);
  const said = entry.answered;
  // A delegation's answer says what it changed: where it went, which parts, the word back.
  // A new artifact's says who reads it and whose it is.
  const detail = said
    ? [
        said.agent && entry.delegation && said.agent !== entry.delegation.agent ? `sent to ${said.agent}` : null,
        entry.publication && (said.visibility || said.teams) ? `${artifactAccessWords({ teams: said.teams ?? (said.visibility?.startsWith("team:") ? [said.visibility.slice("team:".length)] : []), organisation: said.visibility === "organisation" })}${said.owner === "team" ? ", the team's" : ""}` : null,
        said.edited && said.edited.length > 0 ? `edited ${said.edited.map((p) => PART_NAMES[p] ?? p).join(", ").toLowerCase()}` : null,
        said.reason ? `said: ${said.reason}` : null,
      ].filter(Boolean)
    : [];
  return (
    <div className={`decision ${entry.decision ?? "allow"}`}>
      <Pill status={entry.decision === "deny" ? "denied" : "allowed"}>{verb}</Pill>
      <span className="secondary">
        {headline(entry.tool).replace(/\?$/, "").toLowerCase()} · {mine ? "by you" : `by ${by}`}
        {detail.length > 0 ? ` · ${detail.join(" · ")}` : ""}
        {entry.decision === "deny" ? " — nothing was changed" : ""}
      </span>
    </div>
  );
}
