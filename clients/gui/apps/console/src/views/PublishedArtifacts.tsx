// Published artifacts: the administrators' table of what people and their agents have
// published, and a takedown for each. A platform admin sees every one, a person's private
// ones too, since taking one down is theirs; a team admin sees the artifacts of the teams
// they administer (`team:<name>`) and no other.
//
// A row is a title, a kind, who it is for, whose it is (a team's, where a team owns it), its team and its size, never what
// it holds, and nothing here opens one: that is the person's own Artifacts, where an
// administrator who may see one opens it as anybody does. A takedown deletes every version
// and stops every link without asking its owner, so it is typed by the artifact's id.

import { useState } from "react";
import type { JSX } from "react";
import { visibilityWords } from "@troupe/client";
import type { AdminArtifact } from "@troupe/client";
import { useConsole, useLoad } from "../console";
import { AuditNote, Empty, Loaded, Preview, bytes, useChange, when } from "./bits";

const KIND: Record<string, string> = { html: "HTML page", markdown: "Markdown", file: "File" };

/** Whose it is: the team that owns it, with who first published it, or the person. */
function ownerWords(a: AdminArtifact): string {
  const person = !a.owner ? "nobody now (its owner was removed)" : a.owner.display_name && a.owner.display_name !== a.owner.subject ? `${a.owner.display_name} (${a.owner.subject})` : a.owner.subject;
  return a.owner_team ? `the ${a.owner_team} team, published by ${person}` : person;
}

export function PublishedArtifacts(): JSX.Element {
  const { admin, role } = useConsole();
  const [load, reload] = useLoad(() => admin.artifacts(), [admin]);
  const { done, apply } = useChange(reload);
  const [taking, setTaking] = useState<AdminArtifact | null>(null);

  return (
    <div className="page">
      <p className="lead">
        {role === "platform_admin"
          ? "Every artifact published on this plane, private ones included, and a takedown for each. Nothing here opens one."
          : "The artifacts of the teams you administer, and a takedown for each. Nothing here opens one."}
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what="the artifacts" retry={reload}>
        {(rows) =>
          rows.length === 0 ? (
            <Empty title="Nothing published here">{role === "platform_admin" ? "Nobody has published an artifact, or artifacts are switched off." : "Nobody has published an artifact for a team of yours."}</Empty>
          ) : (
            <div className="scroll">
              <table aria-label="Published artifacts">
                <thead>
                  <tr>
                    <th>Title</th>
                    <th>Kind</th>
                    <th>For</th>
                    <th>Owner</th>
                    <th>Team</th>
                    <th className="num">Versions</th>
                    <th className="num">Stored</th>
                    <th>Published</th>
                    <th aria-label="Actions" />
                  </tr>
                </thead>
                <tbody>
                  {rows.map((a) => (
                    <tr key={a.id}>
                      <td>
                        {a.title} <span className="mono muted">{a.id}</span>
                      </td>
                      <td>{KIND[a.kind] ?? a.kind}</td>
                      <td>{a.visibility === "private" ? "its owner alone" : visibilityWords(a.visibility)}</td>
                      <td>{ownerWords(a)}</td>
                      <td>{a.team ?? "—"}</td>
                      <td className="num">{a.version}</td>
                      <td className="num">{bytes(a.total_bytes)}</td>
                      <td>{when(a.published_at)}</td>
                      <td>
                        {a.may_take_down && (
                          <button type="button" className="danger" disabled={taking !== null} onClick={() => setTaking(a)}>
                            Take down
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
      {taking && (
        <Preview
          title={`artifact/${taking.id}`}
          lines={[{ field: "artifact", from: taking.title, to: null }]}
          effects={[
            `This is a takedown: ${taking.title} is ${ownerWords(taking)}'s, and they are not asked first.`,
            `Every version of it is deleted, ${bytes(taking.total_bytes)} in all, and every link to it stops opening.`,
            "A taken-down artifact cannot be brought back.",
          ]}
          verb="Take it down"
          typeToConfirm={taking.id}
          onCancel={() => setTaking(null)}
          onConfirm={async () => {
            const { id, title } = taking;
            await apply("artifact.delete", id, () => admin.takeDownArtifact(id), `${title} is taken down.`);
            setTaking(null);
          }}
        />
      )}
    </div>
  );
}
