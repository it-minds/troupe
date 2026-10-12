// The frames a transcript is drawn in (issue #474, docs/design/frames.md): prose, code,
// diff, tool, reasoning and data, each a header, a body on the rendered surface and its
// affordances; the strip a turn's working folds into; and the curtain line while a turn
// works. What each says is `frames.ts`'s; this file only draws it.
//
// The model's Markdown is read by a parser (marked's lexer, Decision 877) and drawn from
// its tokens as elements, never as HTML: raw HTML in a reply is shown as the text it is,
// so there is nothing to sanitise and nothing a reply can make the page load or run. A
// fenced block is a frame of its own inside the prose, on the prose's surface. Mermaid is
// drawn as its source for now.

import { Fragment, useEffect, useMemo, useState } from "react";
import type { JSX, ReactNode } from "react";
import { Lexer } from "marked";
import type { Token, Tokens } from "marked";
import { BRIEF_PARTS, FINISH_PARTS, isBlobRef, partsOf } from "@troupe/client";
import type { BlobRef, Entry } from "@troupe/client";
import { bytes, cut, dataOf, diffOf, fenceOf, moreLines, numberedSource, saidInHead, stripParts, toolHead, took } from "../frames";
import type { CurtainLine, Detail, Strip } from "../frames";

/** The time, again every `every` milliseconds while `active`: what a running call's and the curtain line's durations count from. */
export function useNow(active: boolean, every = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), every);
    return () => clearInterval(timer);
  }, [active, every]);
  return now;
}

// -- the body of a frame --------------------------------------------------------------------

/**
 * A body's lines, cut past the cap to its first twenty and a line that says the rest,
 * which opens it in place; whole when `full`.
 */
function Cut<T>({
  lines,
  full,
  what,
  children,
}: {
  lines: T[];
  full: boolean;
  what?: [string, string];
  children: (shown: T[]) => ReactNode;
}): JSX.Element {
  const [open, setOpen] = useState(false);
  const { shown, more } = cut(lines, full || open);
  return (
    <>
      {children(shown)}
      {more > 0 && (
        <button type="button" className="more" onClick={() => setOpen(true)} title="Show the rest here">
          {moreLines(more, what)}
        </button>
      )}
    </>
  );
}

/** A frame's header: what it is, then one fact about it. */
function Head({ label, note }: { label: string; note?: string | undefined }): JSX.Element {
  return (
    <div className="frame-head">
      <span className="label">{label}</span>
      {note && <span className="fact">{note}</span>}
    </div>
  );
}

/** Source as it was written, in the reader's ink. */
function Source({ text, full }: { text: string; full: boolean }): JSX.Element {
  return <Cut lines={text.split("\n")} full={full}>{(shown) => <pre>{shown.join("\n")}</pre>}</Cut>;
}

/** A table under its header row, cut past the cap by rows. */
function Table({ columns, rows, full }: { columns: string[]; rows: string[][]; full: boolean }): JSX.Element {
  return (
    <Cut lines={rows} full={full} what={["row", "rows"]}>
      {(shown) => (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                {columns.map((c, i) => (
                  <th key={i}>{c}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {shown.map((row, r) => (
                <tr key={r}>
                  {row.map((cell, i) => (
                    <td key={i}>{cell}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Cut>
  );
}

/**
 * A fenced block, as a frame of its own: code with its language and its path when the
 * fence names one, a diff with its path and `+n −m`, and `csv`, `tsv` or `json` as a table
 * with its row count when it parses as one and as written when it does not. `nested` is a
 * block inside prose, on the prose's surface rather than a second one.
 */
export function FencedFrame({ info, text, full, nested = true }: { info: string | undefined; text: string; full: boolean; nested?: boolean }): JSX.Element {
  const fence = fenceOf(info);
  const at = fence.path ? ` · ${fence.path}` : "";
  const className = `frame ${nested ? "nested " : ""}${fence.kind}`;

  if (fence.kind === "diff") {
    const diff = diffOf(text, fence.path);
    return (
      <div className={className}>
        <Head label="diff" note={diff.note} />
        <Cut lines={diff.lines} full={full}>
          {(shown) => (
            <pre>
              {shown.map((l, i) => (
                <Fragment key={i}>
                  <span className={l.kind}>{l.text}</span>
                  {i < shown.length - 1 ? "\n" : ""}
                </Fragment>
              ))}
            </pre>
          )}
        </Cut>
      </div>
    );
  }

  if (fence.kind === "data") {
    const table = dataOf(fence.label, text);
    return (
      <div className={className}>
        <Head label={fence.label} note={table ? ` · ${table.rows.length === 1 ? "1 row" : `${table.rows.length} rows`}${at}` : at || undefined} />
        {table ? <Table columns={table.columns} rows={table.rows} full={full} /> : <Source text={text} full={full} />}
      </div>
    );
  }

  return (
    <div className={className}>
      <Head label={fence.label} note={at || undefined} />
      <Source text={text} full={full} />
    </div>
  );
}

// -- Markdown --------------------------------------------------------------------------------

/** Where a link may go from a reply: the web, and nothing a click would run or open here. */
const SAFE_HREF = /^https?:\/\//i;

function inline(tokens: Token[] | undefined): ReactNode[] {
  return (tokens ?? []).map((t, i) => <Fragment key={i}>{inlineToken(t)}</Fragment>);
}

function inlineToken(t: Token): ReactNode {
  switch (t.type) {
    case "text": {
      const text = t as Tokens.Text;
      return text.tokens && text.tokens.length > 0 ? inline(text.tokens) : text.text;
    }
    case "escape":
      return (t as Tokens.Escape).text;
    case "strong":
      return <strong>{inline((t as Tokens.Strong).tokens)}</strong>;
    case "em":
      return <em>{inline((t as Tokens.Em).tokens)}</em>;
    case "del":
      return <del>{inline((t as Tokens.Del).tokens)}</del>;
    case "codespan":
      return <code>{(t as Tokens.Codespan).text}</code>;
    case "br":
      return <br />;
    case "link": {
      const link = t as Tokens.Link;
      if (!SAFE_HREF.test(link.href)) return link.raw;
      return (
        <a href={link.href} target="_blank" rel="noreferrer noopener" title={link.title ?? undefined}>
          {inline(link.tokens)}
        </a>
      );
    }
    case "checkbox":
      return <input type="checkbox" checked={(t as Tokens.Checkbox).checked} disabled readOnly aria-label="a task" />;
    // Raw HTML, an image, and anything else the parser knows and this does not draw: as
    // written. An image is never loaded from a reply.
    default:
      return t.raw;
  }
}

function blocks(tokens: Token[], full: boolean): ReactNode[] {
  return tokens.map((t, i) => <Fragment key={i}>{block(t, full)}</Fragment>);
}

function block(t: Token, full: boolean): ReactNode {
  switch (t.type) {
    case "space":
    case "def":
      return null;
    case "heading": {
      const h = t as Tokens.Heading;
      return h.depth <= 2 ? <h3>{inline(h.tokens)}</h3> : <h4>{inline(h.tokens)}</h4>;
    }
    case "paragraph":
      return <p>{inline((t as Tokens.Paragraph).tokens)}</p>;
    // A tight list item's words, and what a task item's box sits beside.
    case "text":
    case "checkbox":
      return inlineToken(t);
    case "list": {
      const list = t as Tokens.List;
      const items = list.items.map((item, i) => (
        <li key={i} className={item.task ? "task" : undefined}>
          {blocks(item.tokens, full)}
        </li>
      ));
      return list.ordered ? <ol start={typeof list.start === "number" && list.start !== 1 ? list.start : undefined}>{items}</ol> : <ul>{items}</ul>;
    }
    case "blockquote":
      return <blockquote>{blocks((t as Tokens.Blockquote).tokens, full)}</blockquote>;
    case "hr":
      return <hr />;
    case "code": {
      const code = t as Tokens.Code;
      return <FencedFrame info={code.lang} text={code.text} full={full} />;
    }
    case "table": {
      const table = t as Tokens.Table;
      const align = (a: "center" | "left" | "right" | null) => (a ? { textAlign: a } : undefined);
      return (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                {table.header.map((cell, i) => (
                  <th key={i} style={align(cell.align)}>
                    {inline(cell.tokens)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {table.rows.map((row, r) => (
                <tr key={r}>
                  {row.map((cell, i) => (
                    <td key={i} style={align(cell.align)}>
                      {inline(cell.tokens)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    }
    // Raw HTML is disallowed, not sanitised: the text it is, on a line of its own.
    case "html":
      return <p className="raw">{(t as Tokens.HTML).text.replace(/\n+$/, "")}</p>;
    default:
      return <p>{t.raw}</p>;
  }
}

/**
 * Markdown, rendered from a parser's tokens: headings, emphasis, inline code, quotes,
 * rules, lists nested to any depth, pipe tables, and fenced blocks as frames of their own
 * — each cut past the cap unless `full`; the prose around them never is.
 */
export function Markdown({ text, full }: { text: string; full: boolean }): JSX.Element {
  const tokens = useMemo(() => Lexer.lex(text, { gfm: true, breaks: false, async: false }), [text]);
  return <div className="md">{blocks(tokens, full)}</div>;
}

/**
 * A prose frame: the model's Markdown, rendered, on the rendered surface, with no header
 * but the toggle that shows what it wrote as written — which settles whether a reply's
 * Markdown is broken or the rendering is.
 */
export function ProseFrame({ text, full }: { text: string; full: boolean }): JSX.Element {
  const [source, setSource] = useState(false);
  return (
    <div className="frame prose">
      <div className="frame-head">
        <button
          type="button"
          className="source-toggle"
          aria-pressed={source}
          onClick={() => setSource((s) => !s)}
          title={source ? "Show it rendered" : "Show the Markdown as the model wrote it"}
        >
          source
        </button>
      </div>
      {source ? <pre className="source">{text}</pre> : <Markdown text={text} full={full} />}
    </div>
  );
}

// -- a call ----------------------------------------------------------------------------------

type ToolEntry = Extract<Entry, { kind: "tool" }>;

/**
 * A result the server replaced with a reference because it ran past 16 KiB. The preview
 * came with the event; the bytes are fetched by range only when somebody asks for them,
 * which is what keeps opening a long session cheap.
 */
function LargeResult({ reference, readBlob, full }: { reference: BlobRef; readBlob: (b: string) => Promise<string>; full: boolean }): JSX.Element {
  const [whole, setWhole] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  return (
    <>
      <Source text={whole ?? reference.preview ?? ""} full={full} />
      {whole === null && (
        <p className="note">
          {bytes(reference.size)} in total.{" "}
          <button
            className="link"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              setError(null);
              readBlob(reference.blob)
                .then(setWhole)
                .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
                .finally(() => setBusy(false));
            }}
          >
            {busy ? "Fetching…" : "Show all of it"}
          </button>
        </p>
      )}
      {error && <p className="note error">{error}</p>}
    </>
  );
}

/** A brief's or a finish's parts under their names (troupe Decision 847). */
function Parts({ parts }: { parts: Array<[string, string]> }): JSX.Element {
  return (
    <dl className="facts wide parts">
      {parts.map(([name, text]) => (
        <Fragment key={name}>
          <dt>{name.replace("_", " ")}</dt>
          <dd>{text}</dd>
        </Fragment>
      ))}
    </dl>
  );
}

/** What came back, on the rendered surface: numbered source for a file read, the text as it came otherwise. */
function Result({ entry, readBlob, full }: { entry: ToolEntry; readBlob: (b: string) => Promise<string>; full: boolean }): JSX.Element | null {
  const content = entry.content;
  if (content === undefined) return null;
  if (isBlobRef(content)) return <LargeResult reference={content} readBlob={readBlob} full={full} />;
  if (saidInHead(entry)) return null;
  const numbered = entry.name === "read_file" ? numberedSource(content) : null;
  if (!numbered) return <Source text={content.replace(/\s+$/, "")} full={full} />;
  const width = Math.max(...numbered.lines.map(([n]) => n.length));
  return (
    <>
      {numbered.head.map((l) => (
        <p key={l} className="note">
          {l}
        </p>
      ))}
      <Cut lines={numbered.lines} full={full}>
        {(shown) => (
          <pre className="numbered" style={{ ["--gutter" as string]: `${width}ch` }}>
            {shown.map(([n, code], i) => (
              <Fragment key={n}>
                <span className="n">{n}</span>
                {code}
                {i < shown.length - 1 ? "\n" : ""}
              </Fragment>
            ))}
          </pre>
        )}
      </Cut>
      {numbered.tail.map((l) => (
        <p key={l} className="note">
          {l}
        </p>
      ))}
    </>
  );
}

/**
 * A tool frame: its header on the chat — glyph, name, target, outcome and how long it
 * took — and what came back under it on the rendered surface. A brief and a finish are
 * read as their parts; any other call's arguments are under the result, open at
 * `everything`, which is what a bug report wants.
 */
export function ToolFrame({ entry, level, readBlob }: { entry: ToolEntry; level: Detail; readBlob: (b: string) => Promise<string> }): JSX.Element {
  const head = toolHead(entry);
  const full = level === "everything";
  const state = entry.ok === undefined ? "running" : entry.ok ? "ok" : "failed";
  const shape = entry.name === "delegate" ? BRIEF_PARTS : entry.name === "finish" ? FINISH_PARTS : null;
  const parts = shape ? partsOf(entry.args, shape) : [];
  const result = <Result entry={entry} readBlob={readBlob} full={full} />;
  const hasResult = entry.content !== undefined && (isBlobRef(entry.content) || !saidInHead(entry));

  return (
    <details className={`tool-frame ${state}`} open>
      <summary className="frame-head">
        <span className="glyph">{head.glyph}</span> <span className="name">{head.name}</span>
        {head.target && (
          <>
            {" "}
            <span className="target">{head.target}</span>
          </>
        )}
        {head.notes.map((n) => (
          <span key={n} className="fact">
            {" · "}
            {n}
          </span>
        ))}
      </summary>
      {(parts.length > 0 || hasResult) && (
        <div className="frame">
          {parts.length > 0 && <Parts parts={parts} />}
          {hasResult && result}
        </div>
      )}
      {parts.length === 0 && entry.args !== undefined && (
        <details className="args" open={full}>
          <summary>arguments</summary>
          <pre>{JSON.stringify(entry.args, null, 2)}</pre>
        </details>
      )}
    </details>
  );
}

// -- reasoning, the strip, the curtain ---------------------------------------------------------

/**
 * What the model thought before it answered: `thinking · 12s` on the chat, and the text,
 * dim and in the reader's ink, on the surface under it. Shut unless the turn is drawn at
 * `everything`; a person can open one by itself.
 */
export function ReasoningFrame({ text, ms, open }: { text: string; ms: number | undefined; open: boolean }): JSX.Element {
  const duration = took(ms);
  return (
    <details className="reasoning-frame" open={open}>
      <summary className="frame-head">thinking{duration ? ` · ${duration}` : ""}</summary>
      <div className="frame">{text}</div>
    </details>
  );
}

/** A turn's working as one line where it began; a click opens the whole turn, and shuts it. */
export function StripLine({ strip, onToggle }: { strip: Strip; onToggle: () => void }): JSX.Element {
  const p = stripParts(strip);
  return (
    <button type="button" className="strip" aria-expanded={strip.open} onClick={onToggle} title={strip.open ? "Shut this turn's working" : "Open this turn's working"}>
      {p.glyph} {p.steps}
      {p.failed && <span className="failed"> · {p.failed}</span>}
      {p.tools && ` · ${p.tools}`}
      {p.took && ` · ${p.took}`}
    </button>
  );
}

/**
 * The line under a turn while it works: the turning mark, a few words from the set, then
 * the facts, which are always there and always last. Waiting on a person is the facts
 * alone, in the reserved colour. It is not read out as it ticks: the header says the same.
 */
export function Curtain({ line }: { line: CurtainLine }): JSX.Element {
  return (
    <p className={`curtain${line.waiting ? " waiting" : ""}`} aria-live="off">
      {!line.waiting && (
        <>
          <span className="spin" aria-hidden="true">
            ◐
          </span>{" "}
        </>
      )}
      {line.flourish && (
        <>
          <span className="flourish">{line.flourish} —</span>{" "}
        </>
      )}
      <span className="doing">{line.facts}</span>
    </p>
  );
}
