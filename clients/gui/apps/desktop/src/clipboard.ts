// Text onto the clipboard, through the shell where there is one.
//
// A page's own `navigator.clipboard.writeText` is granted inside the click that asked and
// not after it: WebKit, the webview on Linux and macOS, refuses one that comes after an
// `await` with "The request is not allowed by the user agent", and a link the daemon mints
// first always comes after one. The shell writes the clipboard from outside the page, on no
// such clock. A browser build has nothing else and writes it itself.

import { shell } from "./shell";

export async function copyText(text: string): Promise<void> {
  const copy = shell()?.copyText;
  if (copy) await copy(text);
  else await navigator.clipboard.writeText(text);
}
