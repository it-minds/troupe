// Bundles: what a session can do, versioned.
//
// Publishing is the one administrative action with a document in it, so it is the one
// where "the error inline, and nothing published" has to be true rather than intended.
// The plane refuses a bad document with one sentence per problem in `data.errors`; this
// screen validates first, shows those sentences where the document is, and only sends
// `publish` once there is nothing to show. A refused publish changes nothing — the
// check the plane runs before writing is the same one `validate` runs.
//
// After a publish the question is not "did it publish" but "did it reach the pods", so
// adoption is polled until every pod on the channel reports the new hash. Nothing here
// makes that happen; it is `config.updated` travelling to pods that were already there.

import { useCallback, useEffect, useState } from "react";
import type { JSX } from "react";
import { bundleErrors } from "@troupe/client";
import type { AdminApi, BundleDetail, BundleSummary } from "@troupe/client";
import { useAdminQuery } from "../../hooks";
import { Loading, Pill, When } from "../bits";
import { AfterTheChange, Confirm, Failed, Table } from "./bits";

export function AdminBundles({ api, platform }: { api: AdminApi; platform: boolean }): JSX.Element {
  const [channel, setChannel] = useState("stable");
  const [typed, setTyped] = useState("stable");
  const [wrote, setWrote] = useState(0);
  const [open, setOpen] = useState<number | null>(null);
  const [publishing, setPublishing] = useState(false);
  const [retiring, setRetiring] = useState<BundleSummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => api.bundles(channel), [api, channel]);
  const { data: bundles, loading, error: readError, reload } = useAdminQuery<BundleSummary[]>(load, [load, wrote]);

  const retire = async (bundle: BundleSummary): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await api.retireBundle(bundle.channel, bundle.version);
      setRetiring(null);
      setWrote((n) => n + 1);
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <section className="group">
        <h3>Channel</h3>
        <form
          className="inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            setChannel(typed.trim() || "stable");
            setOpen(null);
          }}
        >
          <input value={typed} onChange={(e) => setTyped(e.target.value)} aria-label="Channel" spellCheck={false} />
          <button type="submit">Show</button>
          {platform && (
            <button type="button" className="primary" onClick={() => setPublishing(true)}>
              Publish a version
            </button>
          )}
        </form>
        <p className="note">
          Every version of a channel is kept. A rollback is a new version carrying the old content, which is why there is no delete —
          retiring stops anything new from starting on a version and leaves what is running alone.
        </p>
      </section>

      <Failed error={readError ?? error} />
      {loading && !bundles && <Loading what="Reading the channel…" />}

      {bundles && bundles.length === 0 && !loading && (
        <div className="empty">
          <h2>No versions on {channel}</h2>
          <p>Nothing has been published to this channel. A session started on a profile that points at it runs with no bundle.</p>
        </div>
      )}

      {bundles && bundles.length > 0 && (
        <section className="group">
          <h3>Versions of {channel}</h3>
          <Table head={["Version", "State", "What it carries", "Published", "By", "  "]}>
            {bundles.map((b) => (
              <tr key={b.version}>
                <th scope="row">{b.version}</th>
                <td>{b.retired_at ? <Pill status="dormant">Retired</Pill> : <Pill status="allowed">Live</Pill>}</td>
                <td>{summarise(b)}</td>
                <td>
                  <When iso={b.published_at} />
                </td>
                <td className="micro">{b.published_by ?? "—"}</td>
                <td>
                  <button className="link" onClick={() => setOpen(open === b.version ? null : b.version)}>
                    {open === b.version ? "Hide" : "Open"}
                  </button>
                  {platform && !b.retired_at && (
                    <button className="link" onClick={() => setRetiring(b)}>
                      Retire
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        </section>
      )}

      {open !== null && <Version api={api} channel={channel} version={open} />}

      <AfterTheChange api={api} nonce={wrote} />

      {publishing && (
        <Publish
          api={api}
          channel={channel}
          onClose={() => setPublishing(false)}
          onPublished={() => {
            setPublishing(false);
            setWrote((n) => n + 1);
            reload();
          }}
        />
      )}

      {retiring && (
        <Confirm
          what="Retire this version"
          identifier={String(retiring.version)}
          consequence={`Nothing new will start on ${retiring.channel} version ${retiring.version}. Sessions already running on it are untouched and keep the bundle they started with.`}
          busy={busy}
          onCancel={() => setRetiring(null)}
          onConfirm={() => void retire(retiring)}
        />
      )}
    </>
  );
}

function summarise(b: BundleSummary): string {
  const s = b.summary ?? {};
  const parts = [
    s.agents?.length ? `${s.agents.length} agents` : null,
    s.skills?.length ? `${s.skills.length} skills` : null,
    s.mcp_servers?.length ? `${s.mcp_servers.length} MCP servers` : null,
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(", ") : "nothing";
}

/** One version in full, with which pods are actually on it. */
function Version({ api, channel, version }: { api: AdminApi; channel: string; version: number }): JSX.Element {
  const load = useCallback(() => api.bundle(channel, version), [api, channel, version]);
  const { data, loading, error } = useAdminQuery<BundleDetail>(load, [load]);

  return (
    <section className="group">
      <h3>
        {channel} version {version}
      </h3>
      <Failed error={error} />
      {loading && !data && <Loading what="Reading the version…" />}
      {data && (
        <>
          <dl className="facts wide">
            <dt>Hash</dt>
            <dd className="mono micro">{data.hash}</dd>
            <dt>Reached</dt>
            <dd>
              <Adoption adoption={data.adoption} />
            </dd>
          </dl>
          <details className="tool">
            <summary>
              <span className="verb">The document</span>
            </summary>
            <pre className="payload">{JSON.stringify(data.content, null, 2)}</pre>
          </details>
        </>
      )}
    </section>
  );
}

function Adoption({ adoption }: { adoption: BundleDetail["adoption"] }): JSX.Element {
  if (adoption.length === 0) return <span className="when">no profile points at this channel</span>;
  return (
    <>
      {adoption.map((a, i) => {
        const pods = Number(a.pods ?? 0);
        const on = Number(a.on_hash ?? 0);
        return (
          <span key={i} className="chip" title={`${on} of ${pods} pods report this bundle`}>
            {String(a.profile ?? "profile")} {on}/{pods}
          </span>
        );
      })}
    </>
  );
}

/**
 * Publish, in two steps that are two different questions.
 *
 * Validate answers "is this document publishable" and changes nothing. Publish answers
 * "make it the current version". Keeping them apart is what lets the errors be shown
 * against the document rather than against an action that already half-happened.
 */
function Publish({
  api,
  channel,
  onClose,
  onPublished,
}: {
  api: AdminApi;
  channel: string;
  onClose: () => void;
  onPublished: () => void;
}): JSX.Element {
  const [text, setText] = useState('{\n  "agents": [],\n  "skills": [],\n  "mcp_servers": []\n}');
  const [problems, setProblems] = useState<string[] | null>(null);
  const [checked, setChecked] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [published, setPublished] = useState<BundleSummary | null>(null);

  const parse = (): Record<string, unknown> | null => {
    try {
      const doc = JSON.parse(text) as unknown;
      if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
        setProblems(["The document has to be a JSON object with agents, skills and mcp_servers."]);
        return null;
      }
      return doc as Record<string, unknown>;
    } catch (e) {
      setProblems([`That is not valid JSON: ${e instanceof Error ? e.message : String(e)}`]);
      return null;
    }
  };

  const act = async (publish: boolean): Promise<void> => {
    setBusy(true);
    setError(null);
    setProblems(null);
    const doc = parse();
    if (!doc) return void setBusy(false);
    try {
      if (publish) {
        setPublished(await api.publishBundle(channel, doc));
      } else {
        await api.validateBundle(doc);
        setChecked(true);
      }
    } catch (e) {
      const sentences = bundleErrors(e);
      if (sentences) setProblems(sentences);
      else setError(e instanceof Error ? e.message : String(e));
      setChecked(false);
    } finally {
      setBusy(false);
    }
  };

  if (published) return <Published api={api} bundle={published} onDone={onPublished} />;

  return (
    <div className="scrim" onClick={onClose}>
      <div className="dialog wide" role="dialog" aria-modal="true" aria-label="Publish a bundle" onClick={(e) => e.stopPropagation()}>
        <h1>Publish to {channel}</h1>
        <p className="copy">
          Every pod on this channel is told about the new version as soon as it exists. A session already running keeps the bundle it
          started with, so nothing in flight changes under it.
        </p>

        <label>
          The document
          <textarea
            className="mono"
            rows={14}
            value={text}
            spellCheck={false}
            onChange={(e) => {
              setText(e.target.value);
              setChecked(false);
              setProblems(null);
            }}
          />
        </label>

        {problems && (
          <div className="banner error">
            <p>This was not published. {problems.length === 1 ? "One problem:" : `${problems.length} problems:`}</p>
            <ul className="problems">
              {problems.map((p, i) => (
                <li key={i}>{p}</li>
              ))}
            </ul>
          </div>
        )}
        {checked && !problems && <p className="note">Checked. Nothing was published — the document is publishable.</p>}
        <Failed error={error} />

        <div className="actions">
          <button onClick={onClose}>Cancel</button>
          <button onClick={() => void act(false)} disabled={busy}>
            {busy ? "Checking…" : "Check it"}
          </button>
          <button className="primary" onClick={() => void act(true)} disabled={busy}>
            Publish
          </button>
        </div>
      </div>
    </div>
  );
}

/** What happened after: the version, and adoption until every pod has it. */
function Published({ api, bundle, onDone }: { api: AdminApi; bundle: BundleSummary; onDone: () => void }): JSX.Element {
  const [detail, setDetail] = useState<BundleDetail | null>(null);

  useEffect(() => {
    let live = true;
    const tick = (): void => {
      api
        .bundle(bundle.channel, bundle.version)
        .then((d) => live && setDetail(d))
        .catch(() => undefined);
    };
    tick();
    const t = setInterval(tick, 2_000);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, [api, bundle]);

  const pods = (detail?.adoption ?? []).reduce((n, a) => n + Number(a.pods ?? 0), 0);
  const on = (detail?.adoption ?? []).reduce((n, a) => n + Number(a.on_hash ?? 0), 0);
  const everywhere = pods > 0 && on === pods;

  return (
    <div className="scrim">
      <div className="dialog" role="dialog" aria-modal="true" aria-label="Published">
        <h1>
          Published version {bundle.version} of {bundle.channel}
        </h1>
        <dl className="facts wide">
          <dt>Hash</dt>
          <dd className="mono micro">{bundle.hash}</dd>
          <dt>Reached</dt>
          <dd>
            {pods === 0 ? "no profile points at this channel" : `${on} of ${pods} pods`}
            {everywhere ? " — every pod has it" : ""}
          </dd>
        </dl>
        {!everywhere && pods > 0 && <p className="note">Pods take a few seconds. This keeps checking.</p>}
        <div className="actions">
          <button className="primary" onClick={onDone}>
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
