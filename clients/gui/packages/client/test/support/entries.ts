// The plane's reading of a memory document as entries (troupe #55), as the fakes answer it:
// one entry per `## Topic` section, the text before the first heading the entry called
// General; entries written back as sections; and what is in effect among levels, per topic
// the closest level's entry with the lower ones it replaces. The plane's own is
// `Troupe.Protocol.Memory.Entries`; this is enough of it for a fake to answer as it does.

export interface FakeEntry {
  topic: string;
  body: string;
  heading: boolean;
}

export interface FakeLevel {
  level: { scope: string; name: string | null };
  rank: number;
  entries: FakeEntry[];
}

const HEADING = /^##[ \t]+(.+?)[ \t]*#*[ \t]*$/;

/** A document's entries, in order. */
export function parse(text: string): FakeEntry[] {
  const entries: FakeEntry[] = [];
  let topic = "General";
  let heading = false;
  let body: string[] = [];
  const flush = (): void => {
    const said = body.join("\n").replace(/^\s*\n/, "").trim();
    if (heading || said !== "") entries.push({ topic, body: said, heading });
  };
  for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
    const m = HEADING.exec(line);
    if (m) {
      flush();
      topic = m[1]!.trim();
      heading = true;
      body = [];
    } else {
      body.push(line);
    }
  }
  flush();
  return entries;
}

/** The text of a document holding these entries, as the plane writes them. */
export function render(entries: Array<{ topic?: string | null; body?: string; heading?: boolean }>): string {
  return entries
    .map((e) => {
      const body = (e.body ?? "").trim();
      if (e.heading === false || !e.topic) return body;
      return body === "" ? `## ${e.topic.trim()}` : `## ${e.topic.trim()}\n\n${body}`;
    })
    .filter((part) => part !== "")
    .join("\n\n");
}

const key = (topic: string): string => topic.trim().replace(/\s+/g, " ").toLowerCase();

/** Per topic the closest level's entry, where the topic first comes, with what it replaces, closest first. */
export function inEffect(levels: FakeLevel[]): Array<FakeEntry & { level: FakeLevel["level"]; replaces: Array<{ level: FakeLevel["level"]; topic: string; body: string }> }> {
  const closest = new Map<string, number>();
  for (const l of levels) for (const e of l.entries) if (e.heading) closest.set(key(e.topic), Math.max(closest.get(key(e.topic)) ?? -1, l.rank));
  const slots: string[] = [];
  levels.forEach((l, at) =>
    l.entries.forEach((e, i) => {
      const slot = e.heading ? `t:${key(e.topic)}` : `g:${at}:${i}`;
      if (!slots.includes(slot)) slots.push(slot);
    }),
  );
  const out: Array<FakeEntry & { level: FakeLevel["level"]; replaces: Array<{ level: FakeLevel["level"]; topic: string; body: string }> }> = [];
  for (const slot of slots) {
    levels.forEach((l, at) =>
      l.entries.forEach((e, i) => {
        if (e.heading ? slot !== `t:${key(e.topic)}` || closest.get(key(e.topic)) !== l.rank : slot !== `g:${at}:${i}`) return;
        const replaces = e.heading
          ? [...levels]
              .filter((lower) => lower.rank < l.rank)
              .sort((a, b) => b.rank - a.rank)
              .flatMap((lower) => lower.entries.filter((x) => x.heading && key(x.topic) === key(e.topic)).map((x) => ({ level: lower.level, topic: x.topic, body: x.body })))
          : [];
        out.push({ ...e, level: l.level, replaces });
      }),
    );
  }
  return out;
}
