// What is in force in a team session on its pod, and where each part came from (troupe
// #655's follow-up): the pod answers `config.get` naming the session over its own
// connection, with its worker profile's settings and rules, what the platform enforces,
// the terms the session was created with and its repository's files.
//
// Shown, never edited: none of it is this computer's to write. The keys listed are those
// something set; the rest are the defaults. The terminal UI's `/settings` shows the same in
// a pod session, and `troupe config --explain --session <id>` says it in a terminal.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { keySource, ruleScope } from "@troupe/client";
import type { SessionConfig, SessionView } from "@troupe/client";
import { Loading, Table } from "./bits";

export function PodConfig({ view }: { view: SessionView | null }): JSX.Element {
  const [config, setConfig] = useState<SessionConfig | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!view) return;
    let live = true;
    view
      .config()
      .then((c) => live && setConfig(c))
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));
    return () => {
      live = false;
    };
  }, [view]);

  if (error) return <p className="note">The pod did not say what is in force here: {error}</p>;
  if (!config) return <Loading what="Reading what is in force on the pod…" />;

  const set = config.keys.filter((k) => k.layer !== "default");
  const shown = (value: unknown): string => (typeof value === "string" ? value : JSON.stringify(value));

  return (
    <>
      <p className="muted micro">In force in this session on its pod: its profile's, the platform's, its terms and its repository's. Nothing here changes it.</p>
      <Table head={["Setting", "Value", "From"]}>
        {set.map((k) => (
          <tr key={k.key}>
            <td>
              <code>{k.key}</code>
            </td>
            <td>{shown(k.value)}</td>
            <td>{keySource(k)}</td>
          </tr>
        ))}
      </Table>
      {config.permissions.length > 0 && (
        <Table head={["Rule", "Does", "From"]}>
          {config.permissions.map((r, i) => (
            <tr key={`${r.scope}-${r.action}-${r.rule}-${i}`} className={r.ignored ? "muted" : undefined}>
              <td>
                <code>{r.rule}</code>
              </td>
              <td>{r.ignored ? `${r.action}, not applied: ${r.ignored}` : r.action}</td>
              <td>
                {ruleScope(r)}
                {r.source && <div className="micro muted">{r.source}</div>}
              </td>
            </tr>
          ))}
        </Table>
      )}
      {config.warnings.map((w) => (
        <p key={w} className="note">
          {w}
        </p>
      ))}
    </>
  );
}
