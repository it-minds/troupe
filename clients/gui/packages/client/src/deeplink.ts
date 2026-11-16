// Links into the desktop app, and the banner that offers it on a web page (troupe #959).
//
// The app owns the `troupe:` scheme and takes three forms, each a place it already shows:
//
//   troupe://open?plane=<url>              sign in to that plane, or come to the front
//   troupe://session/<id>?plane=<url>      that session's view
//   troupe://artifact/<id>?plane=<url>     that artifact in the gallery
//
// `open` may leave out the plane (the docs site has none to name), and then only brings the
// app forward. A link is an address and nothing more: it never carries a token, a code or
// a credential, and a parameter other than `plane` is a link this app did not write, so it
// is refused whole rather than followed with the rest ignored. What the app does with a
// plane it is not signed in to is the app's: it asks in words before any request is made.
//
// The banner half is plain functions over the page's own objects (navigator, document,
// storage), so the console's React banner and the plain scripts on other pages can follow
// the same rules, and a test can hold them without a browser.

export type AppLink = { kind: "open"; plane: string | null } | { kind: "session"; id: string; plane: string } | { kind: "artifact"; id: string; plane: string };

/** A link the app will not follow, and the one sentence that says why. */
export interface RefusedLink {
  refused: string;
}

export const LINK_SCHEME = "troupe:";

/** What a session or an artifact id may be: the plane's own ids, and nothing that could be a path. */
const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

/** No link is longer than this; the plane's ids and addresses are a fraction of it. */
const MAX_LINK = 2048;

const NOT_FOLLOWED = "This link was not followed:";

/**
 * A plane's address as links carry it and the app compares it: its origin and any path,
 * with no trailing slash, no query, no fragment and no user or password. http only for
 * this computer, as the app signs in over it only in development. Null when it is not one.
 */
export function planeAddress(text: string): string | null {
  let url: URL;
  try {
    url = new URL(text.trim());
  } catch {
    return null;
  }
  if (url.username || url.password || url.search || url.hash) return null;
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) return null;
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

/** The link for a place, with the plane's address as `planeAddress` writes it. */
export function appLink(link: AppLink): string {
  const plane = link.plane ? planeAddress(link.plane) ?? link.plane : null;
  const query = plane ? `?plane=${encodeURIComponent(plane)}` : "";
  if (link.kind === "open") return `troupe://open${query}`;
  return `troupe://${link.kind}/${encodeURIComponent(link.id)}${query}`;
}

/**
 * Read a link handed to the app: one of the three forms, or a sentence saying why it is
 * not followed. Nothing in it is taken beyond the place and the plane's address.
 */
export function parseAppLink(text: string): AppLink | RefusedLink {
  if (text.length > MAX_LINK) return { refused: `${NOT_FOLLOWED} it is longer than any link Troupe writes.` };
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return { refused: `${NOT_FOLLOWED} it is not an address.` };
  }
  if (url.protocol !== LINK_SCHEME) return { refused: `${NOT_FOLLOWED} it is not a troupe:// link.` };
  if (url.username || url.password || url.hash) return { refused: `${NOT_FOLLOWED} it carries more than a place and a plane.` };
  const extra = [...url.searchParams.keys()].filter((k) => k !== "plane");
  if (extra.length > 0 || url.searchParams.getAll("plane").length > 1) {
    return { refused: `${NOT_FOLLOWED} it carries more than a place and a plane, and Troupe takes nothing else from a link.` };
  }
  const given = url.searchParams.get("plane");
  const plane = given === null ? null : planeAddress(given);
  if (given !== null && plane === null) return { refused: `${NOT_FOLLOWED} its plane is not an https address.` };
  const place = url.host;
  const rest = url.pathname.replace(/^\/+/, "");
  if (place === "open") {
    if (rest) return { refused: `${NOT_FOLLOWED} Troupe does not know that place.` };
    return { kind: "open", plane };
  }
  if (place === "session" || place === "artifact") {
    let id: string;
    try {
      id = decodeURIComponent(rest);
    } catch {
      return { refused: `${NOT_FOLLOWED} its ${place} is not an id.` };
    }
    if (!ID.test(id)) return { refused: `${NOT_FOLLOWED} its ${place} is not an id.` };
    if (plane === null) return { refused: `${NOT_FOLLOWED} it does not say which plane the ${place} is on.` };
    return { kind: place, id, plane };
  }
  return { refused: `${NOT_FOLLOWED} Troupe does not know that place.` };
}

export function isRefused(link: AppLink | RefusedLink): link is RefusedLink {
  return "refused" in link;
}

/** The host a plane's address names, as a sentence says it. */
export function planeHost(plane: string): string {
  try {
    return new URL(plane).host;
  } catch {
    return plane;
  }
}

// -- the banner ------------------------------------------------------------------------

/** Where the page is read: one of the three the app is built for, a phone, or neither. */
export type BannerPlatform = "windows" | "macos" | "linux" | "phone" | "other";

/**
 * The platform from what the browser says of itself. An iPad that asks for the desktop
 * site says Macintosh, and is told apart by its touch points; a Chromebook is `other`.
 */
export function platformOf(userAgent: string, maxTouchPoints = 0): BannerPlatform {
  if (/Android|iPhone|iPad|iPod|Mobile/i.test(userAgent)) return "phone";
  if (/Macintosh|Mac OS X/i.test(userAgent)) return maxTouchPoints > 1 ? "phone" : "macos";
  if (/Windows/i.test(userAgent)) return "windows";
  if (/CrOS/i.test(userAgent)) return "other";
  if (/Linux|X11/i.test(userAgent)) return "linux";
  return "other";
}

/** The release a plane recommends, as its discovery document names it (`plane.downloads`). */
export interface AppDownloads {
  /** The desktop app's recommended version, or null where the plane recommends none. */
  version: string | null;
  /** The release's page, or where releases are listed; always somewhere to go. */
  page: string;
  windows: string | null;
  macos: string | null;
  linux: string | null;
}

/** Where releases are listed when nothing names a version: the public release page. */
export const RELEASES_PAGE = "https://github.com/it-minds/troupe/releases/latest";

/** What a discovery document says of downloads, or the release page where it says nothing usable. */
export function downloadsOf(discovery: { plane?: { [k: string]: unknown } } | null | undefined): AppDownloads {
  const d = discovery?.plane?.["downloads"];
  const none: AppDownloads = { version: null, page: RELEASES_PAGE, windows: null, macos: null, linux: null };
  if (!d || typeof d !== "object") return none;
  const o = d as Record<string, unknown>;
  const url = (v: unknown): string | null => (typeof v === "string" && /^https?:\/\//.test(v) ? v : null);
  return {
    version: typeof o["version"] === "string" ? o["version"] : null,
    page: url(o["page"]) ?? RELEASES_PAGE,
    windows: url(o["windows"]),
    macos: url(o["macos"]),
    linux: url(o["linux"]),
  };
}

export const PLATFORM_NAME: Record<"windows" | "macos" | "linux", string> = { windows: "Windows", macos: "macOS", linux: "Linux" };

/** The storage key a dismissal is kept under, and what it holds: the version it was dismissed at. */
export const BANNER_DISMISSED = "troupe.appBanner.dismissed";

function versionWord(version: string | null): string {
  return version ?? "any";
}

/** Whether this browser dismissed the banner at this recommended version. Storage that cannot be read has dismissed nothing. */
export function bannerDismissed(storage: Pick<Storage, "getItem"> | null | undefined, version: string | null): boolean {
  try {
    return storage?.getItem(BANNER_DISMISSED) === versionWord(version);
  } catch {
    return false;
  }
}

/** Keep the dismissal, until the plane recommends another version. */
export function dismissBanner(storage: Pick<Storage, "setItem"> | null | undefined, version: string | null): void {
  try {
    storage?.setItem(BANNER_DISMISSED, versionWord(version));
  } catch {
    // A browser that keeps nothing shows the banner again next time; nothing else is lost.
  }
}

/** Whether this page is running inside the desktop app, where the banner never shows. */
export function inDesktopApp(win: unknown): boolean {
  const w = win as { __TAURI__?: unknown; __TAURI_INTERNALS__?: unknown } | null | undefined;
  return Boolean(w && (w.__TAURI__ !== undefined || w.__TAURI_INTERNALS__ !== undefined));
}

/** How long a link is given to open the app before the banner offers the install. */
export const OPEN_WAIT_MS = 1500;

export interface OpenWatch {
  /** The page is told the link is being followed. */
  follow(link: string): void;
  /** Hear the page lose sight or focus; returns the function that stops hearing it. */
  onLeave(listener: () => void): () => void;
  wait(ms: number, then: () => void): () => void;
}

/**
 * Follow `link` and say whether the app seemed to open: `opened` when the page lost sight
 * or focus within `OPEN_WAIT_MS`, else `nothing`.
 *
 * A guess, and said to be one. No browser tells a page whether a scheme has a handler. An
 * app that opens takes the focus, which the page hears as `blur` or `visibilitychange`; a
 * browser that knows no handler does nothing (Chrome, Edge), shows its own line (Firefox)
 * or an alert (Safari), and the page keeps the focus. So the guess is wrong both ways at
 * the edges: Chrome's "Open Troupe?" question takes the focus too, so a person who then
 * cancels it is not offered the install; and an app that is installed but slow to start, or
 * a browser that asks nothing and opens nothing, reads as not installed. Either way the
 * person still has both links in front of them.
 */
export function followAppLink(link: string, watch: OpenWatch, ms = OPEN_WAIT_MS): Promise<"opened" | "nothing"> {
  return new Promise((resolve) => {
    let settled = false;
    const done = (how: "opened" | "nothing"): void => {
      if (settled) return;
      settled = true;
      stopLeave();
      stopWait();
      resolve(how);
    };
    const stopLeave = watch.onLeave(() => done("opened"));
    const stopWait = watch.wait(ms, () => done("nothing"));
    watch.follow(link);
  });
}

/** The watch over a real page: its location, its blur and its visibility. */
export function pageWatch(win: Window): OpenWatch {
  return {
    follow: (link) => {
      win.location.href = link;
    },
    onLeave: (listener) => {
      const hidden = (): void => {
        if (win.document.visibilityState === "hidden") listener();
      };
      win.addEventListener("blur", listener);
      win.document.addEventListener("visibilitychange", hidden);
      return () => {
        win.removeEventListener("blur", listener);
        win.document.removeEventListener("visibilitychange", hidden);
      };
    },
    wait: (ms, then) => {
      const t = win.setTimeout(then, ms);
      return () => win.clearTimeout(t);
    },
  };
}

/** What the banner says, by where it is read and how far it has got. */
export const BANNER_WORDS = {
  lead: "Troupe is better in the app.",
  open: "Open in the app",
  install: "Install",
  dismiss: "Dismiss",
  phone: "Troupe's app is for a computer. Send yourself the link to this page to open it there.",
  copyLink: "Copy the link",
  copied: "Copied",
  nothingOpened: "The app did not open, so it may not be installed here.",
  installFor: (platform: string, version: string | null) => (version ? `Install Troupe ${version} for ${platform}` : `Install Troupe for ${platform}`),
  installAny: "Install Troupe from its release page",
} as const;
