// Which workspace folder Troupe opens in.
//
// The active editor's folder, which in a multi-root workspace is the one being worked on;
// with no editor, the folder of the Troupe terminal in front, so that a second press from
// that terminal finds it again instead of asking; then the only folder there is. Two or
// more with nothing to go by is a question, and none at all is nothing to open.

export type Choice<F> = { folder: F } | { ask: readonly F[] } | { none: true };

export function chooseFolder<F>(from: {
  editor?: F | undefined;
  terminal?: F | undefined;
  folders: readonly F[];
}): Choice<F> {
  const known = from.editor ?? from.terminal;
  if (known !== undefined) return { folder: known };

  const [only, ...others] = from.folders;
  if (only === undefined) return { none: true };
  return others.length === 0 ? { folder: only } : { ask: from.folders };
}
