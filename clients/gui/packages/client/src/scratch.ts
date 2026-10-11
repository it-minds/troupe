// The session's scratchpad (issue #472). An agent's `show` writes a named document there
// instead of printing a long answer in the chat, and writing the same name again replaces
// it. Each write is a durable `scratch_updated`, so the documents a session has are a fold
// over its events like the transcript is: a client that attaches late, or comes back
// after a drop, has every one of them from the replay.
//
// The text is not in the events. It is read with `fs.read` on the document's
// `scratch:/<name>` path, when somebody opens it.

import type { DurableEvent, ScratchDocument } from "./types.js";

/** What a document is, as `show` and `scratch_updated` name it; a client renders each its own way. */
export const SCRATCH_KINDS = ["markdown", "mermaid", "json", "csv", "text"] as const;

/** The document a `scratch_updated` says was written, or nothing for one without a name. */
export function scratchDocumentOf(d: DurableEvent): ScratchDocument | undefined {
  const data = d.data;
  const name = typeof data["name"] === "string" ? data["name"] : "";
  if (!name) return undefined;
  const callId = data["call_id"];
  return {
    name,
    path: typeof data["path"] === "string" && data["path"] ? data["path"] : `scratch:/${name}`,
    kind: typeof data["kind"] === "string" && data["kind"] ? data["kind"] : "text",
    title: typeof data["title"] === "string" && data["title"] ? data["title"] : name,
    size: whole(data["size"]) ?? 0,
    hash: typeof data["hash"] === "string" ? data["hash"] : "",
    version: whole(data["version"]) ?? 1,
    updated_at: d.ts,
    ...(typeof callId === "string" && callId ? { call_id: callId } : {}),
  };
}

/**
 * The documents after one more `scratch_updated`: a name written for the first time goes
 * on the end, and one written again takes its place with its new version. An event for a
 * version older than the one held changes nothing, so the same events folded twice leave
 * the same list.
 */
export function foldScratch(docs: ScratchDocument[], d: DurableEvent): ScratchDocument[] {
  const doc = scratchDocumentOf(d);
  if (!doc) return docs;
  const at = docs.findIndex((x) => x.name === doc.name);
  if (at < 0) return [...docs, doc];
  if (doc.version < docs[at]!.version) return docs;
  return docs.map((x, i) => (i === at ? doc : x));
}

/** A document's size the way a person reads one: `512 bytes`, `2.3 KB`, `1.4 MB`. */
export function scratchSize(bytes: number): string {
  if (bytes === 1) return "1 byte";
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/** Which write of its name a version is: `new` for the first, `updated N times` after. */
export function scratchVersion(version: number | undefined): string | undefined {
  if (version === undefined) return undefined;
  return version <= 1 ? "new" : `updated ${version} times`;
}

/**
 * A `show` call's card in one line: the title, the name, the size and which write it is,
 * each once it is known. Until the call's `scratch_updated` arrives the card has what the
 * call's arguments said, and no count.
 */
export function scratchLine(card: { title: string; name: string; size: number | undefined; version: number | undefined }): string {
  const size = card.size === undefined ? undefined : scratchSize(card.size);
  return [card.title || card.name || "a document", card.name && card.name !== card.title ? card.name : undefined, size, scratchVersion(card.version)]
    .filter((part): part is string => Boolean(part))
    .join(" · ");
}

function whole(v: unknown): number | undefined {
  return typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : undefined;
}
