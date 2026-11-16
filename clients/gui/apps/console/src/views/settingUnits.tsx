// A platform setting as a person reads it: named by its label, its value in its unit, and
// asked for in that unit, converted to what the plane keeps on the way out.
//
// The label and the unit are the plane's, written once in its settings table and carried
// on `admin.settings.list` and `admin.setting.effective`, so nothing here lists settings.
// A plane from before them answers neither, and the setting is named by its key and asked
// for as it always was: a switch for a boolean, a select for a set of values, else text.

import type { JSX } from "react";
import type { AuditChanges, SettingNaming } from "@troupe/client";
import { show } from "../console";
import { bytes, duration, money } from "./bits";
import type { DiffLine, FieldProps } from "./bits";

/** What a setting is read in here: the plane's unit, or what an older plane's type implies. */
export interface Unit {
  unit: string;
  choices: Array<{ value: string; label: string }>;
}

type Named = SettingNaming & { key: string; type?: string; values?: string[] | null };

/** The setting's name: its label, or its key where the plane gives none. */
export function nameOf(setting: Named): string {
  return setting.label || setting.key;
}

/** Whether the plane named the setting, so its key is a subtitle rather than its name. */
export function labelled(setting: Named): boolean {
  return Boolean(setting.label);
}

export function unitOf(setting: Named): Unit {
  if (setting.label && setting.unit) {
    const choices = setting.choices ?? (setting.values ?? []).map((v) => ({ value: v, label: v }));
    return { unit: setting.unit, choices };
  }
  if (setting.type === "boolean") return { unit: "switch", choices: [] };
  if (setting.values) return { unit: "choice", choices: setting.values.map((v) => ({ value: v, label: v })) };
  return { unit: "text", choices: [] };
}

const DAY = 86_400;

/** A value as the plane keeps it, in the words of its unit: `$500.00`, `30 min`, `12 days`, `on`. */
export function inUnit(u: Unit, value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  const n = typeof value === "number" ? value : Number(value);
  switch (u.unit) {
    case "dollars":
      return Number.isFinite(n) ? (n === 0 ? "no ceiling" : money(n)) : show(value);
    case "minutes":
    case "seconds":
      return Number.isFinite(n) ? duration(n) : show(value);
    case "days":
      return Number.isFinite(n) ? (n === 1 ? "1 day" : `${n} days`) : show(value);
    case "days_or_off":
      return Number.isFinite(n) ? (n === 0 ? "off" : n === 1 ? "1 day" : `${n} days`) : show(value);
    case "bytes":
      return Number.isFinite(n) ? bytes(n) : show(value);
    case "switch":
      return value === true || value === "true" ? "on" : value === false || value === "false" ? "off" : show(value);
    case "choice":
      return u.choices.find((c) => c.value === String(value))?.label ?? show(value);
    default:
      return show(value);
  }
}

/** What the field says the unit is, before the setting's own sentence. */
export function unitHint(u: Unit): string {
  switch (u.unit) {
    case "dollars":
      return "In dollars.";
    case "minutes":
      return "In minutes.";
    case "seconds":
      return "In seconds.";
    case "days":
      return "In days.";
    case "days_or_off":
      return "In days; 0 or off keeps everything.";
    case "bytes":
      return "In bytes.";
    case "count":
      return "A whole number.";
    default:
      return "";
  }
}

/** The plane's value as the field holds it: dollars for millionths, minutes for seconds. */
export function toDraft(u: Unit, value: unknown): string {
  if (value === null || value === undefined) return "";
  const n = Number(value);
  if (u.unit === "dollars" && Number.isFinite(n)) return trim(n / 1_000_000);
  if (u.unit === "minutes" && Number.isFinite(n)) return trim(n / 60);
  return String(value);
}

function trim(n: number): string {
  return String(Math.round(n * 1_000_000) / 1_000_000);
}

/**
 * What the field holds, as the plane takes it, or why it is not a value of the unit. The
 * plane parses what it is sent again; this is so the preview says the value that will be
 * stored, not what was typed.
 */
export function fromDraft(u: Unit, text: string): { value: string } | { error: string } {
  const t = text.trim();
  switch (u.unit) {
    case "dollars":
      return /^\d+(\.\d{1,6})?$/.test(t) ? { value: String(Math.round(Number(t) * 1_000_000)) } : { error: "An amount in dollars, like 500 or 12.50." };
    case "minutes":
      return /^\d+(\.\d+)?$/.test(t) ? { value: String(Math.round(Number(t) * 60)) } : { error: "A number of minutes, like 30." };
    case "seconds":
    case "days":
    case "bytes":
    case "count":
      return /^\d+$/.test(t) ? { value: t } : { error: "A whole number." };
    case "days_or_off":
      if (t === "" || t.toLowerCase() === "off") return { value: "0" };
      return /^\d+$/.test(t) ? { value: t } : { error: "A whole number of days, or 0 or off to keep everything." };
    default:
      return { value: text };
  }
}

/** The audit's diff for a setting, with the setting's name for the key and each value in its unit. */
export function changesInUnit(setting: Named, changes: AuditChanges): Record<string, unknown> {
  if (!labelled(setting)) return changes;
  const u = unitOf(setting);
  return Object.fromEntries(
    Object.entries(changes).map(([field, c]) => {
      const moved = c as { from?: unknown; to?: unknown };
      return [field === setting.key ? nameOf(setting) : field, { from: inUnit(u, moved.from), to: inUnit(u, moved.to) }];
    }),
  );
}

/** A preview's line for a setting: named by it, from and to in its unit. */
export function lineInUnit(setting: Named, line: DiffLine): DiffLine {
  if (!labelled(setting)) return line;
  const u = unitOf(setting);
  return { field: nameOf(setting), from: inUnit(u, line.from), to: inUnit(u, line.to) };
}

/** The control a unit is asked for in: a switch, a select of a choice's words, else a field. */
export function UnitControl({
  unit,
  value,
  onChange,
  control,
  secret = false,
}: {
  unit: Unit;
  value: string;
  onChange: (v: string) => void;
  control: FieldProps;
  secret?: boolean;
}): JSX.Element {
  if (unit.unit === "switch") {
    return (
      <select {...control} value={value} onChange={(e) => onChange(e.target.value)}>
        {value !== "true" && value !== "false" && <option value={value}>{value || "unset"}</option>}
        <option value="true">on</option>
        <option value="false">off</option>
      </select>
    );
  }
  if (unit.unit === "choice") {
    return (
      <select {...control} value={value} onChange={(e) => onChange(e.target.value)}>
        {!unit.choices.some((c) => c.value === value) && <option value={value}>{value || "unset"}</option>}
        {unit.choices.map((c) => (
          <option key={c.value} value={c.value}>
            {c.label}
          </option>
        ))}
      </select>
    );
  }
  const numeric = ["dollars", "minutes", "seconds", "days", "days_or_off", "bytes", "count"].includes(unit.unit);
  return (
    <input
      {...control}
      type={secret ? "password" : "text"}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      inputMode={numeric ? (unit.unit === "dollars" || unit.unit === "minutes" ? "decimal" : "numeric") : unit.unit === "url" ? "url" : undefined}
      spellCheck={false}
      autoComplete="off"
    />
  );
}
