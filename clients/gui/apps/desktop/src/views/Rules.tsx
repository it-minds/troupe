// The per-tool permission rules a session on this computer runs under (troupe #658).
//
// Shown, never edited: a rule is a line of a config file, the user's own, a project's or
// the organisation's, and the daemon says which (`config.get`'s `permissions`). Every
// file's rules count together, the strictest that matches a call holding, so the panel
// lists them all with where each came from, and a rule that does not apply says why. The
// terminal UI's `/settings` shows the same list, and `troupe config --explain permissions`
// says the same in a terminal.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { ruleScope } from "@troupe/client";
import type { DaemonClient, PermissionRule } from "@troupe/client";
import { Table } from "./bits";

export function Rules({ client }: { client: DaemonClient }): JSX.Element | null {
  const [rules, setRules] = useState<PermissionRule[] | null>(null);

  useEffect(() => {
    let live = true;
    const read = (): void => {
      client
        .modelConfig()
        .then((c) => live && setRules(c.permissions ?? null))
        .catch(() => live && setRules(null));
    };
    read();
    const stop = client.onConfigChanged(read);
    return () => {
      live = false;
      stop();
    };
  }, [client]);

  // A daemon older than the rules says nothing about them, and the panel is not drawn.
  if (rules === null) return null;

  return (
    <section className="group" aria-label="Permission rules">
      <h3>Permission rules</h3>
      {rules.length === 0 ? (
        <p className="muted">
          No rules: a write, an edit, a command, a web fetch or a server's tool asks before it runs. A <code>permissions:</code> block in a config file
          answers in advance.
        </p>
      ) : (
        <>
          <Table head={["Rule", "Does", "From"]}>
            {rules.map((r, i) => (
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
          <p className="muted micro">Every file's rules count together: deny beats ask beats allow, and inside one file the more specific rule decides.</p>
        </>
      )}
    </section>
  );
}
