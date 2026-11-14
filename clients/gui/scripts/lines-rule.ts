// The picking rule for the status lines, and the seeds its fixture is written for.
//
// `scripts/lines.ts` copies everything below the marker into the generated reader
// (`packages/client/src/lines.ts`), so the rule is written once; the terminal client's
// `mix troupe.lines` writes the same rule in Elixir, and `clients/gui/docs/design/lines.order.json`,
// generated here, is what holds the two to each other.

/** The seeds the order fixture is written for: empty, plain, an id with a counter, and one with non-ASCII bytes. */
export const LINE_SEEDS: readonly string[] = ["", "a", "turn-7", "ses_01HZXQ/3", "ünïcode ☺"];

// -- the picking rule ---------------------------------------------------------------------

/*
 * Per turn, or per wait, the lines of a kind are taken in an order shuffled from a seed, the
 * turn's id, else the session's, else a counter: so within a turn nothing repeats, two turns
 * do not open the same way, and past the end of the list there is no line, which is the
 * facts alone. The seed is hashed with the kind's name (FNV-1a over the UTF-8 bytes of
 * `kind`, a slash, `seed`) into a 32-bit state; the state steps as mulberry32 does; the
 * order is a Fisher-Yates shuffle from the end, each draw taken modulo the places left.
 * Every operation is on unsigned 32 bits, so Elixir's integers say the same thing.
 */

function fnv1a(text: string): number {
  let h = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(text)) {
    h = Math.imul(h ^ byte, 0x01000193) >>> 0;
  }
  return h;
}

/** The indices 0..length-1 in the order the kind's lines are taken for the seed. */
export function orderOf(kind: string, seed: string, length: number): number[] {
  let a = fnv1a(`${kind}/${seed}`);
  const next = (): number => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (t ^ (t >>> 14)) >>> 0;
  };
  const indices = Array.from({ length }, (_, i) => i);
  for (let i = length - 1; i > 0; i--) {
    const j = next() % (i + 1);
    const held = indices[i]!;
    indices[i] = indices[j]!;
    indices[j] = held;
  }
  return indices;
}
