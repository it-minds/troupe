// Links into the desktop app (troupe #959): the three forms are read and written the same
// way, anything else is refused with a sentence, a link never carries more than a place and
// a plane's address, and the banner's rules (platform, dismissal, the open-or-install guess)
// hold without a browser.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  BANNER_DISMISSED,
  appLink,
  bannerDismissed,
  dismissBanner,
  downloadsOf,
  followAppLink,
  inDesktopApp,
  isRefused,
  parseAppLink,
  planeAddress,
  platformOf,
  RELEASES_PAGE,
} from "../src/index.js";
import type { OpenWatch } from "../src/index.js";

const PLANE = "https://troupe.example.com";

describe("the three forms", () => {
  it("open names a plane, or none", () => {
    assert.deepEqual(parseAppLink(`troupe://open?plane=${encodeURIComponent(PLANE)}`), { kind: "open", plane: PLANE });
    assert.deepEqual(parseAppLink("troupe://open"), { kind: "open", plane: null });
  });

  it("a session and an artifact name their id and their plane", () => {
    assert.deepEqual(parseAppLink(`troupe://session/s-7f3a?plane=${encodeURIComponent(PLANE)}`), { kind: "session", id: "s-7f3a", plane: PLANE });
    assert.deepEqual(parseAppLink(`troupe://artifact/a_19?plane=${encodeURIComponent(`${PLANE}/`)}`), { kind: "artifact", id: "a_19", plane: PLANE });
  });

  it("what appLink writes, parseAppLink reads back", () => {
    for (const link of [
      { kind: "open" as const, plane: PLANE },
      { kind: "open" as const, plane: null },
      { kind: "session" as const, id: "s-1", plane: "https://example.org/troupe" },
      { kind: "artifact" as const, id: "a-2", plane: "http://localhost:4000" },
    ]) {
      assert.deepEqual(parseAppLink(appLink(link)), link);
    }
    assert.equal(appLink({ kind: "session", id: "s-1", plane: `${PLANE}/` }), "troupe://session/s-1?plane=https%3A%2F%2Ftroupe.example.com");
  });
});

describe("what a link may not carry", () => {
  const refused = (text: string): string => {
    const read = parseAppLink(text);
    assert.ok(isRefused(read), `${text} was followed`);
    return read.refused;
  };

  it("a token, a code or any other parameter refuses the whole link", () => {
    for (const extra of ["token=abc", "code=123", "access_token=x", "plane2=y"]) {
      assert.match(refused(`troupe://session/s-1?plane=${encodeURIComponent(PLANE)}&${extra}`), /takes nothing else from a link/);
    }
    assert.match(refused(`troupe://open?plane=${encodeURIComponent(PLANE)}&plane=${encodeURIComponent("https://other.example")}`), /more than a place/);
    assert.match(refused(`troupe://open?plane=${encodeURIComponent(PLANE)}#frag`), /more than a place/);
    assert.match(refused(`troupe://user:secret@open?plane=${encodeURIComponent(PLANE)}`), /more than a place/);
  });

  it("a plane that is not https, or that carries a password or a query, is refused", () => {
    for (const plane of ["http://troupe.example.com", "ftp://troupe.example.com", "https://ada:pw@troupe.example.com", "https://troupe.example.com/?next=x", "not a url", "javascript:alert(1)"]) {
      assert.match(refused(`troupe://open?plane=${encodeURIComponent(plane)}`), /not an https address/, plane);
    }
  });

  it("an unknown place, a missing plane or an id that could be a path is refused", () => {
    assert.match(refused(`troupe://settings?plane=${encodeURIComponent(PLANE)}`), /does not know that place/);
    assert.match(refused(`troupe://open/extra?plane=${encodeURIComponent(PLANE)}`), /does not know that place/);
    assert.match(refused("troupe://session/s-1"), /which plane/);
    assert.match(refused(`troupe://session/${encodeURIComponent("../etc")}?plane=${encodeURIComponent(PLANE)}`), /not an id/);
    assert.match(refused(`troupe://artifact/a/b?plane=${encodeURIComponent(PLANE)}`), /not an id/);
    assert.match(refused(`troupe://artifact/?plane=${encodeURIComponent(PLANE)}`), /not an id/);
  });

  it("another scheme, no address at all, or a link far longer than Troupe writes is refused", () => {
    assert.match(refused(`https://troupe.example.com/session/s-1`), /not a troupe:\/\/ link/);
    assert.match(refused("troupe"), /not an address/);
    assert.match(refused(`troupe://open?plane=${"a".repeat(3000)}`), /longer than any link/);
  });

  it("a plane's address is its origin and path, and http only for this computer", () => {
    assert.equal(planeAddress("https://troupe.example.com/"), PLANE);
    assert.equal(planeAddress("https://troupe.example.com/a/b//"), `${PLANE}/a/b`);
    assert.equal(planeAddress("http://127.0.0.1:4000"), "http://127.0.0.1:4000");
    assert.equal(planeAddress("http://troupe.example.com"), null);
  });
});

describe("the banner", () => {
  it("knows the three platforms and a phone from what the browser says", () => {
    assert.equal(platformOf("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/141.0"), "windows");
    assert.equal(platformOf("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"), "macos");
    assert.equal(platformOf("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", 5), "phone");
    assert.equal(platformOf("Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"), "linux");
    assert.equal(platformOf("Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/141.0 Mobile Safari/537.36"), "phone");
    assert.equal(platformOf("Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"), "phone");
    assert.equal(platformOf("Mozilla/5.0 (X11; CrOS x86_64 16000.0.0) AppleWebKit/537.36 Chrome/141.0"), "other");
  });

  it("a dismissal holds until the recommended version changes, and storage that throws dismisses nothing", () => {
    const kept = new Map<string, string>();
    const storage = { getItem: (k: string) => kept.get(k) ?? null, setItem: (k: string, v: string) => void kept.set(k, v) };
    assert.equal(bannerDismissed(storage, "0.39.0-beta"), false);
    dismissBanner(storage, "0.39.0-beta");
    assert.equal(kept.get(BANNER_DISMISSED), "0.39.0-beta");
    assert.equal(bannerDismissed(storage, "0.39.0-beta"), true);
    assert.equal(bannerDismissed(storage, "0.40.0-beta"), false);
    const throws = {
      getItem: () => {
        throw new Error("denied");
      },
      setItem: () => {
        throw new Error("denied");
      },
    };
    assert.equal(bannerDismissed(throws, null), false);
    assert.doesNotThrow(() => dismissBanner(throws, null));
  });

  it("is never drawn inside the desktop app", () => {
    assert.equal(inDesktopApp({ __TAURI__: {} }), true);
    assert.equal(inDesktopApp({ __TAURI_INTERNALS__: {} }), true);
    assert.equal(inDesktopApp({}), false);
  });

  it("reads the plane's downloads, and falls back to the release page", () => {
    assert.deepEqual(downloadsOf(null), { version: null, page: RELEASES_PAGE, windows: null, macos: null, linux: null });
    const d = downloadsOf({
      plane: { downloads: { version: "0.39.0-beta", page: "https://example.org/r", windows: "https://example.org/w.exe", macos: "javascript:alert(1)", linux: 7 } },
    });
    assert.deepEqual(d, { version: "0.39.0-beta", page: "https://example.org/r", windows: "https://example.org/w.exe", macos: null, linux: null });
  });

  const watch = (leaves: boolean): { watch: OpenWatch; followed: string[] } => {
    const followed: string[] = [];
    let leave: (() => void) | null = null;
    let timer: (() => void) | null = null;
    return {
      followed,
      watch: {
        follow: (link) => {
          followed.push(link);
          if (leaves) leave?.();
          else timer?.();
        },
        onLeave: (l) => {
          leave = l;
          return () => (leave = null);
        },
        wait: (_ms, then) => {
          timer = then;
          return () => (timer = null);
        },
      },
    };
  };

  it("an app that takes the focus is taken as opened, and a page that keeps it as nothing opened", async () => {
    const opened = watch(true);
    assert.equal(await followAppLink("troupe://open", opened.watch), "opened");
    assert.deepEqual(opened.followed, ["troupe://open"]);
    const nothing = watch(false);
    assert.equal(await followAppLink("troupe://open", nothing.watch), "nothing");
  });
});
