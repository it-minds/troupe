// What the desktop app and the console both say, written once.
//
// An error, a size, an amount of money, a length of time, how long ago something was and
// a session's state each read one way in both apps, and the way the terminal client says
// them where it shows the same thing (`Troupe.Protocol.Words` and the TUI's `dollars`).

/**
 * An error as a sentence: the server's own `reason` where its refusal gave one, else an
 * `Error`'s message, else the value itself. `fallback` stands in for a thrown value that
 * is neither an error nor a string.
 */
export function errorText(e: unknown, fallback?: string): string {
  const reason = (e as { data?: { reason?: unknown } } | null | undefined)?.data?.reason;
  if (typeof reason === "string" && reason !== "") return reason;
  if (e instanceof Error) return e.message;
  if (typeof e === "string") return e;
  return fallback ?? String(e);
}

const UNITS = ["KiB", "MiB", "GiB", "TiB"];

/**
 * A size as a person reads it: `0 bytes`, `1 byte`, `1023 bytes`, `1.5 KiB`, `2 MiB`. Binary
 * units, as the plane's limits are set and as a disk is measured; one decimal place, left
 * out when it is `0`. Nothing reported is `—`.
 */
export function bytes(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return "—";
  if (n < 1024) return n === 1 ? "1 byte" : `${n} bytes`;
  let size = n / 1024;
  let unit = 0;
  while (Math.round(size * 10) / 10 >= 1024 && unit < UNITS.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${tenths(Math.round(size * 10))} ${UNITS[unit]}`;
}

/**
 * Micros (millionths of a dollar, as the plane and the daemon count money) as money:
 * `$0.00`, `under a cent`, `$1.00`, `$1,473.50`, rounded half up to the cent. Nothing
 * reported is `—`, which is not the same as free.
 */
export function moneyWords(micros: number | null | undefined): string {
  if (micros === null || micros === undefined || !Number.isFinite(micros)) return "—";
  if (micros === 0) return "$0.00";
  const size = Math.abs(micros);
  if (size < 10_000) return "under a cent";
  const cents = Math.floor((size + 5_000) / 10_000);
  const dollars = Math.floor(cents / 100).toLocaleString("en");
  return `${micros < 0 ? "−" : ""}$${dollars}.${String(cents % 100).padStart(2, "0")}`;
}

/** A count of something, its thousands grouped: `1 token`, `8,192 tokens`, `3 levels`. */
export function countWords(n: number, one: string, many = `${one}s`): string {
  return `${n.toLocaleString("en")} ${n === 1 ? one : many}`;
}

/**
 * A length of time in milliseconds, in words: `0 s`, `1.5 s`, `59 s`, `1 min`, `1 min 30 s`,
 * `1 h 1 min`. Under a minute the seconds keep one decimal place, left out when it is `0`;
 * from a minute up, hours, minutes and whole seconds, a part that is `0` left out.
 *
 * `adjective` is a limit's size before its noun, as the stop sentence says it ("its
 * 30-minute working limit"): `45-second`, `30-minute`, `2-hour`, hours only when whole.
 * `long` is a limit said in a sentence ("works for at most 30 minutes"): `45 seconds`,
 * `30 minutes`, `1 hour 30 minutes`, whole seconds, a part that is `0` left out.
 * Nothing reported is `—`.
 */
export function durationWords(ms: number | null | undefined, style: "words" | "adjective" | "long" = "words"): string {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return "—";
  const t = Math.max(0, Math.trunc(ms));
  if (style === "long") {
    const seconds = Math.round(t / 1000);
    const parts: Array<[number, string]> = [
      [Math.floor(seconds / 3600), "hour"],
      [Math.floor((seconds % 3600) / 60), "minute"],
      [seconds % 60, "second"],
    ];
    const said = parts.filter(([n]) => n !== 0).map(([n, unit]) => countWords(n, unit));
    return said.length === 0 ? "0 seconds" : said.join(" ");
  }
  if (style === "adjective") {
    if (t >= 3_600_000 && t % 3_600_000 === 0) return `${t / 3_600_000}-hour`;
    if (t >= 60_000) return `${Math.round(t / 60_000)}-minute`;
    return `${Math.round(t / 1000)}-second`;
  }
  if (t < 59_950) return `${tenths(Math.round(t / 100))} s`;
  const seconds = Math.max(60, Math.floor(t / 1000));
  const parts: Array<[number, string]> = [
    [Math.floor(seconds / 3600), "h"],
    [Math.floor((seconds % 3600) / 60), "min"],
    [seconds % 60, "s"],
  ];
  return parts
    .filter(([n]) => n !== 0)
    .map(([n, unit]) => `${n} ${unit}`)
    .join(" ");
}

/**
 * How long ago `then` was at `now`: `just now`, `3 min ago`, `2 h ago`, `yesterday`,
 * `4 days ago`, and the date (`2026-10-01`) from thirty days on. A time that does not read
 * as one is `—`.
 */
export function ago(then: number | string | Date, now: number = Date.now()): string {
  const at = typeof then === "number" ? then : new Date(then).getTime();
  if (!Number.isFinite(at)) return "—";
  const s = Math.floor((now - at) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 2 * 86_400) return "yesterday";
  if (s < 30 * 86_400) return `${Math.floor(s / 86_400)} days ago`;
  return new Date(at).toISOString().slice(0, 10);
}

function tenths(n: number): string {
  return n % 10 === 0 ? String(n / 10) : `${Math.floor(n / 10)}.${n % 10}`;
}

/**
 * A session's state, and what an active one is doing, as both apps say it: the
 * daemon's and the plane's `active`, `dormant`, `read_only` and `erasure_pending`, and
 * the desktop's `working`, `waiting`, `idle` and `failed` read from an active one's status.
 */
const SESSION_STATES: Record<string, string> = {
  active: "Active",
  working: "Working",
  waiting: "Waiting for you",
  idle: "Idle",
  failed: "Failed",
  dormant: "Asleep",
  read_only: "Read only",
  erasure_pending: "Erasure pending",
};

/** A session's state in a word, never the protocol's key; one the table does not know reads as its key in words. */
export function sessionStateWords(state: string): string {
  const said = SESSION_STATES[state];
  if (said) return said;
  const words = state.replace(/_/g, " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}
