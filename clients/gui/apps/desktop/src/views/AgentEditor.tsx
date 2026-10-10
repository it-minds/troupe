// One agent's file, edited: a form for its frontmatter, its instruction as text, and the
// whole file for anything the form does not do (troupe #503).
//
// The file's text is the one thing held. The form reads its fields out of it and writes a
// change back into it (`withFields`), leaving every line it did not edit as it was, so a
// key the form does not know survives; the instruction tab replaces the body alone; the
// file tab is the text itself. Nothing is checked here: the daemon checks a definition on
// Check and on Save, and what it finds is shown at the field it names, on the tab that has
// that field, with nothing written.
//
// Above Save is what the agent may do, every `auto` named, and what this save adds to it:
// the screen asks once, before writing, when the save lets a tool run without asking that
// did not before (`Agents.tsx`).

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { findingsFor, parseAgent, permissionsOf, widenedAutos, withBody, withFields } from "@troupe/client";
import type { AgentCheck, AgentDefinition, AgentFields, AgentFinding, AgentScope, DaemonClient } from "@troupe/client";

/** Where a scope's file is, in words. */
export function scopeWords(scope: AgentScope): string {
  return scope === "user" ? "your agents" : "this repository's .troupe/agents";
}

/** What a permission lets the agent do, in words. */
export function permissionWords(p: string): string {
  return p === "auto" ? "runs without asking" : p === "deny" ? "never" : p === "ask" ? "asks first" : p;
}

/** What the editor holds: a new agent or a file being changed, its text, and what the daemon last found. */
export interface Editing {
  kind: "new" | "edit";
  name: string;
  scope: AgentScope;
  text: string;
  /** The definition it was opened from: the file it changes, or the one it was made from. */
  original: AgentDefinition | null;
  findings: AgentCheck | null;
  /** Whether `findings` came from Check rather than from a refused save. */
  checked: boolean;
}

type Tab = "frontmatter" | "instruction" | "file";

const FORM_FIELDS = ["description", "mode", "model", "tools", "permissions", "max_turns", "budget_share", "skills", "override"];

/** Which tab shows a finding about a field. */
function tabOf(field: string): Tab | "top" {
  if (field === "name" || field === "scope" || field === "workspace") return "top";
  if (field === "prompt") return "instruction";
  if (FORM_FIELDS.includes(field) || field.startsWith("permissions.")) return "frontmatter";
  return "file";
}

/** The permissions of the file a save replaces: the one it was opened from, where the save goes to the same file. */
function replaced(editing: Editing): Record<string, string> {
  const o = editing.original;
  return o && o.name === editing.name && o.layer === editing.scope ? o.permissions : {};
}

export function AgentEditor({
  client,
  workspace,
  editing,
  busy,
  onChange,
  onCancel,
  onSave,
}: {
  client: DaemonClient;
  workspace: string;
  editing: Editing;
  busy: boolean;
  onChange: (next: Editing) => void;
  onCancel: () => void;
  onSave: (target: { name: string; scope: AgentScope; text: string; before: Record<string, string> }) => void;
}): JSX.Element {
  const [tab, setTab] = useState<Tab>("frontmatter");
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const parsed = parseAgent(editing.text);
  const all: Array<AgentFinding & { error: boolean }> = [
    ...(editing.findings?.errors ?? []).map((f) => ({ ...f, error: true })),
    ...(editing.findings?.warnings ?? []).map((f) => ({ ...f, error: false })),
  ];
  const errorsIn = (t: Tab): number => (editing.findings?.errors ?? []).filter((f) => tabOf(f.field) === t).length;
  const set = (patch: Partial<Editing>): void => onChange({ ...editing, ...patch });
  const setText = (text: string): void => set({ text });
  const title = editing.kind === "edit" ? `Edit ${editing.name}` : editing.original ? `New agent from ${editing.original.name}` : "New agent";

  const check = async (): Promise<void> => {
    setChecking(true);
    setCheckError(null);
    try {
      const findings = await client.validateAgent({ source: editing.text, ...(editing.name ? { name: editing.name } : {}), ...(workspace ? { workspace } : {}) });
      onChange({ ...editing, findings, checked: true });
    } catch (e) {
      setCheckError(e instanceof Error ? e.message : String(e));
    } finally {
      setChecking(false);
    }
  };

  return (
    <section className="group agent-editor" aria-label={title}>
      <h3>{title}</h3>
      {editing.findings && editing.findings.errors.length > 0 && (
        <div className="banner error" role="alert">
          <p>
            {editing.checked ? "Not saved yet, and it would not be:" : "Not saved:"} {editing.findings.errors.length}{" "}
            {editing.findings.errors.length === 1 ? "thing to fix" : "things to fix"}, each marked where it is
            {(["frontmatter", "instruction", "file"] as Tab[])
              .filter((t) => errorsIn(t) > 0)
              .map((t) => ` · ${TAB_NAMES[t]} (${errorsIn(t)})`)
              .join("")}
            .
          </p>
        </div>
      )}
      {editing.findings?.ok && editing.checked && <p className="note">The daemon finds nothing wrong with it.</p>}
      {checkError && <p className="note error">{checkError}</p>}

      <div className="fields agent-where">
        <label>
          Name
          <input
            value={editing.name}
            onChange={(e) => set({ name: e.target.value, findings: null })}
            disabled={editing.kind === "edit"}
            placeholder="review"
            spellCheck={false}
            aria-label="Name"
          />
          <small>{editing.kind === "edit" ? "a new name is a new agent: New agent from this" : "lowercase letters, digits and dashes"}</small>
        </label>
        <label>
          Save to
          <select value={editing.scope} onChange={(e) => set({ scope: e.target.value as AgentScope })} aria-label="Save to">
            <option value="user">my agents (every session on this computer)</option>
            <option value="project" disabled={!workspace}>
              this repository&apos;s .troupe/agents (committed, shared)
            </option>
          </select>
        </label>
      </div>
      <Notes list={all.filter((f) => tabOf(f.field) === "top")} />

      <div className="tabs" role="tablist">
        {(["frontmatter", "instruction", "file"] as Tab[]).map((t) => (
          <button key={t} className="tab" role="tab" aria-selected={tab === t} onClick={() => setTab(t)}>
            {TAB_NAMES[t]}
            {errorsIn(t) > 0 ? ` (${errorsIn(t)})` : ""}
          </button>
        ))}
      </div>

      {tab === "frontmatter" &&
        (parsed.fields ? (
          <Form fields={parsed.fields} other={parsed.other} findings={all} onChange={(patch) => setText(withFields(editing.text, patch))} />
        ) : (
          <p className="note error">{parsed.problem}. The File tab has it as it is.</p>
        ))}

      {tab === "instruction" && (
        <label className="agent-body">
          The instruction <small>what the agent is told, under Troupe&apos;s own prompt</small>
          <textarea value={parsed.body} onChange={(e) => setText(withBody(editing.text, e.target.value))} rows={14} spellCheck={false} aria-label="Instruction" className="mono" />
          <Notes list={all.filter((f) => tabOf(f.field) === "instruction")} />
        </label>
      )}

      {tab === "file" && (
        <label className="agent-body">
          The file <small>frontmatter and instruction, as it is written</small>
          <textarea value={editing.text} onChange={(e) => setText(e.target.value)} rows={18} spellCheck={false} aria-label="File" className="mono" />
          <Notes list={all.filter((f) => tabOf(f.field) === "file")} />
        </label>
      )}

      <MayDo editing={editing} />

      <div className="actions start-actions">
        <button onClick={() => void check()} disabled={checking || busy}>
          {checking ? "Checking…" : "Check"}
        </button>
        <button
          className="primary"
          disabled={busy || editing.name.trim() === ""}
          onClick={() => onSave({ name: editing.name.trim(), scope: editing.scope, text: editing.text, before: replaced(editing) })}
        >
          {busy ? "Saving…" : `Save to ${scopeWords(editing.scope)}`}
        </button>
        <button onClick={onCancel}>Cancel</button>
      </div>
    </section>
  );
}

const TAB_NAMES: Record<Tab, string> = { frontmatter: "Frontmatter", instruction: "Instruction", file: "File" };

/** What the daemon found about one field: errors in the error colour, warnings as notes. */
function Notes({ list }: { list: Array<AgentFinding & { error: boolean }> }): JSX.Element | null {
  if (list.length === 0) return null;
  return (
    <>
      {list.map((f, i) => (
        <p key={`${f.field}-${i}`} className={`note field-note ${f.error ? "error" : ""}`} data-field={f.field}>
          {f.message}
        </p>
      ))}
    </>
  );
}

/**
 * What the agent may do, as the text being saved says it: every `auto` named, then the
 * asks and the denials, and what this save adds to the file it replaces.
 */
function MayDo({ editing }: { editing: Editing }): JSX.Element {
  const permissions = permissionsOf(editing.text);
  if (permissions === null) {
    return (
      <div className="may-do">
        <p className="note error">The form cannot read its permissions: read them in the File tab before saving.</p>
      </div>
    );
  }
  const by = (p: string): string[] =>
    Object.entries(permissions)
      .filter(([, v]) => v === p)
      .map(([tool]) => tool)
      .sort();
  const widened = widenedAutos(replaced(editing), permissions);
  return (
    <div className="may-do" aria-label="What it may do">
      <h4>What it may do</h4>
      <dl className="facts wide">
        {(["auto", "ask", "deny"] as const).map((p) => {
          const tools = by(p);
          return tools.length === 0 ? null : (
            <div key={p} className="may-do-row">
              <dt>{permissionWords(p)}</dt>
              <dd className="mono">{tools.join(", ")}</dd>
            </div>
          );
        })}
        <div className="may-do-row">
          <dt>everything else</dt>
          <dd>each tool it holds keeps Troupe&apos;s own permission</dd>
        </div>
      </dl>
      <p className="note">
        {editing.scope === "user"
          ? "Your agents are read by every session on this computer, in every workspace; an auto there asks no workspace's trust."
          : "The repository's agents are committed and shared; an auto there applies once the workspace is trusted."}
        {widened.length > 0 && ` This save lets ${widened.join(", ")} run without asking, which the file it replaces did not: you are asked once before it is written.`}
      </p>
    </div>
  );
}

/** A list of names, one per line, kept as typed while it is being typed. */
function ListField({ value, onChange, label }: { value: string[]; onChange: (v: string[]) => void; label: string }): JSX.Element {
  const read = (text: string): string[] =>
    text
      .split(/[\n,]/)
      .map((s) => s.trim())
      .filter(Boolean);
  const [draft, setDraft] = useState(value.join("\n"));
  useEffect(() => {
    if (JSON.stringify(read(draft)) !== JSON.stringify(value)) setDraft(value.join("\n"));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);
  return (
    <textarea
      value={draft}
      onChange={(e) => {
        setDraft(e.target.value);
        onChange(read(e.target.value));
      }}
      rows={Math.min(Math.max(value.length + 1, 3), 12)}
      spellCheck={false}
      aria-label={label}
      className="mono"
    />
  );
}

function Form({
  fields,
  other,
  findings,
  onChange,
}: {
  fields: AgentFields;
  other: string[];
  findings: Array<AgentFinding & { error: boolean }>;
  onChange: (patch: Partial<AgentFields>) => void;
}): JSX.Element {
  const notes = (field: string): JSX.Element | null => <Notes list={findingsFor(findings, field).map((f) => f as AgentFinding & { error: boolean })} />;
  const permissions = Object.entries(fields.permissions);
  const setPermissions = (rows: Array<[string, string]>): void => onChange({ permissions: Object.fromEntries(rows) });
  const skills = fields.skills === "all" ? "all" : fields.skills.length === 0 ? "none" : "these";

  return (
    <div className="agent-form">
      <label>
        Description <small>one line, shown beside the name wherever an agent is chosen</small>
        <input value={fields.description} onChange={(e) => onChange({ description: e.target.value })} aria-label="Description" />
      </label>
      {notes("description")}

      <div className="fields">
        <label>
          Mode
          <select value={fields.mode} onChange={(e) => onChange({ mode: e.target.value })} aria-label="Mode">
            {fields.mode !== "primary" && fields.mode !== "subagent" && <option value={fields.mode}>{fields.mode || "(not set)"}</option>}
            <option value="primary">primary: a session or a branch runs it</option>
            <option value="subagent">subagent: an agent delegates to it</option>
          </select>
          {notes("mode")}
        </label>
        <label>
          Model <small>default, cheap, expensive or a model&apos;s name; empty runs on the session&apos;s</small>
          <input value={fields.model} onChange={(e) => onChange({ model: e.target.value })} spellCheck={false} aria-label="Model" className="mono" />
          {notes("model")}
        </label>
      </div>

      <div className="fields">
        <label>
          Max turns <small>empty: no cap of its own</small>
          <input value={fields.max_turns} onChange={(e) => onChange({ max_turns: e.target.value })} inputMode="numeric" aria-label="Max turns" />
          {notes("max_turns")}
        </label>
        <label>
          Budget share <small>of the session&apos;s budget, above 0 and at most 1</small>
          <input value={fields.budget_share} onChange={(e) => onChange({ budget_share: e.target.value })} inputMode="decimal" aria-label="Budget share" />
          {notes("budget_share")}
        </label>
      </div>

      <fieldset className="agent-tools">
        <legend>Tools</legend>
        <label className="inline">
          <input type="checkbox" checked={fields.tools === "all"} onChange={(e) => onChange({ tools: e.target.checked ? "all" : [] })} />
          Every tool the harness has
        </label>
        {fields.tools !== "all" && <ListField value={fields.tools} onChange={(tools) => onChange({ tools })} label="Tools" />}
        {notes("tools")}
      </fieldset>

      <fieldset className="agent-permissions">
        <legend>Permissions</legend>
        <p className="note">A tool not named here keeps Troupe&apos;s own permission. auto runs it without asking; deny takes it away.</p>
        {permissions.map(([tool, p], i) => (
          <div key={i} className="permission-row">
            <input
              value={tool}
              onChange={(e) => setPermissions(permissions.map((row, j) => (j === i ? [e.target.value, row[1]] : row)))}
              placeholder="shell"
              spellCheck={false}
              aria-label={`Permission ${i + 1} tool`}
              className="mono"
            />
            <select value={p} onChange={(e) => setPermissions(permissions.map((row, j) => (j === i ? [row[0], e.target.value] : row)))} aria-label={`Permission for ${tool || "the tool"}`}>
              {!["auto", "ask", "deny"].includes(p) && <option value={p}>{p}</option>}
              <option value="ask">ask: asks first</option>
              <option value="auto">auto: runs without asking</option>
              <option value="deny">deny: never</option>
            </select>
            <button type="button" className="link" onClick={() => setPermissions(permissions.filter((_, j) => j !== i))}>
              Remove
            </button>
            {notes(`permissions.${tool}`)}
          </div>
        ))}
        <button type="button" onClick={() => !("" in fields.permissions) && setPermissions([...permissions, ["", "ask"]])} disabled={"" in fields.permissions}>
          Add a permission
        </button>
        <Notes list={findings.filter((f) => f.field === "permissions")} />
      </fieldset>

      <fieldset className="agent-skills">
        <legend>Skills</legend>
        <select
          value={skills}
          onChange={(e) => onChange({ skills: e.target.value === "all" ? "all" : e.target.value === "none" ? [] : ["skill-name"] })}
          aria-label="Skills"
        >
          <option value="none">none</option>
          <option value="all">every skill</option>
          <option value="these">these</option>
        </select>
        {skills === "these" && Array.isArray(fields.skills) && <ListField value={fields.skills} onChange={(s) => onChange({ skills: s })} label="Skill names" />}
        {notes("skills")}
      </fieldset>

      {other.length > 0 && <p className="note">Also in the file, kept as it is written: {other.join(", ")}. Change those in the File tab.</p>}
      {notes("override")}
    </div>
  );
}
