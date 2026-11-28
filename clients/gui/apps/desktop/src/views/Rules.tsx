// The per-tool permission rules a session on this computer runs under (troupe #658), and a
// sensitive session's (troupe #1239).
//
// Shown, never edited: a rule is a line of a config file, the user's own, a project's or
// the organisation's, and the daemon says which (`config.get`'s `permissions` and
// `sensitive`). Every file's rules count together, the strictest that matches a call
// holding, so the panel lists them all with where each came from, and a rule that does not
// apply says why. A sensitive session's are the organisation's enforced file's, beyond the
// person's reach, and their own config.yaml's, which only adds. The terminal UI's
// `/settings` shows the same lists, and `troupe config --explain` says the same in a terminal.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { ruleScope } from "@troupe/client";
import type { DaemonClient, PermissionRule, SensitiveConfig } from "@troupe/client";
import { Table } from "./bits";

export function Rules({ client }: { client: DaemonClient }): JSX.Element | null {
  const [rules, setRules] = useState<PermissionRule[] | null>(null);
  const [sensitive, setSensitive] = useState<SensitiveConfig | null>(null);

  useEffect(() => {
    let live = true;
    const read = (): void => {
      client
        .modelConfig()
        .then((c) => {
          if (!live) return;
          setRules(c.permissions ?? null);
          setSensitive(c.sensitive ?? null);
        })
        .catch(() => {
          if (!live) return;
          setRules(null);
          setSensitive(null);
        });
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
    <>
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
                    <From scope={r.scope} source={r.source} />
                  </td>
                </tr>
              ))}
            </Table>
            <p className="muted micro">Every file's rules count together: deny beats ask beats allow, and inside one file the more specific rule decides.</p>
          </>
        )}
      </section>
      {sensitive && <Sensitive sensitive={sensitive} />}
    </>
  );
}

// Which calls make a session here sensitive, what a sensitive one is refused, and whether it
// may be shared, each with whose word it is. Drawn only where something sets them.
function Sensitive({ sensitive }: { sensitive: SensitiveConfig }): JSX.Element {
  const rows = [...sensitive.marked_by.map((r) => ({ r, does: "marks it sensitive" })), ...sensitive.deny.map((r) => ({ r, does: "refused once sensitive" }))];
  const sharing = sensitive.sharing;
  return (
    <section className="group" aria-label="Sensitive sessions">
      <h3>Sensitive sessions</h3>
      <Table head={["Rule", "Does", "From"]}>
        {rows.map(({ r, does }, i) => (
          <tr key={`${does}-${r.scope}-${r.rule}-${i}`}>
            <td>
              <code>{r.rule}</code>
            </td>
            <td>{does}</td>
            <td>
              <From scope={r.scope} source={r.source} />
            </td>
          </tr>
        ))}
        <tr>
          <td>
            <code>sharing: {sharing.value}</code>
          </td>
          <td>{sharingWords(sharing.value)}</td>
          <td>{sharing.scope ? <From scope={sharing.scope} source={sharing.source} /> : "the default"}</td>
        </tr>
      </Table>
      <p className="muted micro">
        Nothing clears a mark. Your config.yaml may add rules and tighten sharing; what your organisation sets is beyond it.
      </p>
    </section>
  );
}

function From({ scope, source }: { scope: string; source: string | null }): JSX.Element {
  return (
    <>
      {ruleScope({ scope, source })}
      {source && <div className="micro muted">{source}</div>}
    </>
  );
}

// On this computer `ask` refuses as `deny` does: no team administrator answers a laptop's request.
function sharingWords(value: SensitiveConfig["sharing"]["value"]): string {
  if (value === "allow") return "a sensitive session may be offered or invited into";
  if (value === "ask") return "refused here: no team administrator answers a request from this computer";
  return "a sensitive session is not shared beyond who reads it now";
}
