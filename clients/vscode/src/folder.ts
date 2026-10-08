// Which workspace folder Troupe opens in, and the name of its terminal.
//
// The one asked for, a row of the side bar's list; then the active editor's folder, which
// in a multi-root workspace is the one being worked on;
// with no editor, the folder of the Troupe terminal in front, so that a second press from
// that terminal finds it again instead of asking; then the only folder there is. Two or
// more with nothing to go by is a question, and none at all is nothing to open.

export type Choice<F> = { folder: F } | { ask: readonly F[] } | { none: true };

/**
 * The name of a folder's Troupe terminal, which the profile's terminal has too, and by
 * which a terminal Troupe did not open itself is known as Troupe's (startup.ts).
 */
export function terminalName(folder: string): string {
  return `Troupe: ${folder}`;
}

export function chooseFolder<F>(from: {
  given?: F | undefined;
  editor?: F | undefined;
  terminal?: F | undefined;
  folders: readonly F[];
}): Choice<F> {
  const known = from.given ?? from.editor ?? from.terminal;
  if (known !== undefined) return { folder: known };

  const [only, ...others] = from.folders;
  if (only === undefined) return { none: true };
  return others.length === 0 ? { folder: only } : { ask: from.folders };
}
