// What the fakes say the artifacts host blocks in a published page (troupe #1081). The plane
// reads every kind its policy blocks; a fake needs only enough to show the line and the
// list: a stylesheet from another site, an inline script and an inline event handler.

/** One blocked reference, as a version's `blocked` lists it. */
export interface FakeBlocked {
  file: string;
  kind: string;
  reference: string;
  line: number;
}

/** What the fake finds in a version's files, each `{path, content}` with its text. */
export function fakeBlocked(files: Array<{ path: string; content: string }>): FakeBlocked[] {
  const found: FakeBlocked[] = [];
  for (const f of files) {
    if (!/\.html?$/i.test(f.path)) continue;
    f.content.split("\n").forEach((text, i) => {
      const line = i + 1;
      for (const m of text.matchAll(/<link\b[^>]*\bhref=["']((?:https?:)?\/\/[^"']+)["'][^>]*>/gi)) {
        if (/stylesheet/i.test(m[0])) found.push({ file: f.path, kind: "stylesheet", reference: m[1]!, line });
      }
      for (const m of text.matchAll(/<script\b(?![^>]*\bsrc=)[^>]*>([^<]*)/gi)) {
        if (m[1]!.trim()) found.push({ file: f.path, kind: "inline_script", reference: `<script> ${m[1]!.trim()}`, line });
      }
      for (const m of text.matchAll(/\s(on[a-z]+)=["']([^"']*)["']/gi)) found.push({ file: f.path, kind: "event_handler", reference: `${m[1]!}="${m[2]!}"`, line });
    });
  }
  return found;
}
