// The app's Content-Security-Policy, as the image's nginx sends it (issue #460, Decision
// 803). The app keeps the local daemon's token in `localStorage` and the daemon admits the
// plane's origin (Decision 797), so nothing but the app's own bundle may run on that
// origin: no inline script, no eval, no other script origin. The plane's own responses
// carry the plane's copy, which `content_security_policy_test.exs` checks; this is the
// app's, read from the files the image is built from, since no nginx runs here.

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { daemonUrl } from "@troupe/client";

const read = (path: string): string => readFileSync(new URL(path, import.meta.url), "utf8");

const headers = read("../../../docker/headers.conf");
const nginx = read("../../../docker/nginx.conf");
const dockerfile = read("../../../Dockerfile");
const page = read("../index.html");

/** The policy `headers.conf` adds, as `{ "script-src": ["'self'"], … }`. */
function policy(): Record<string, string[]> {
  const found = [...headers.matchAll(/^\s*add_header\s+Content-Security-Policy\s+"([^"]+)"\s+always;/gm)];
  expect(found, "headers.conf adds exactly one Content-Security-Policy, on every status").toHaveLength(1);
  return Object.fromEntries(
    found[0]![1]!
      .split(";")
      .map((d) => d.trim().split(/\s+/))
      .filter((d) => d[0])
      .map(([name, ...sources]) => [name!.toLowerCase(), sources]),
  );
}

/** Whether a CSP source expression admits a URL. Enough of CSP's matching for the sources used here. */
function admits(source: string, url: string): boolean {
  const target = new URL(url);
  if (/^[a-z][a-z0-9+.-]*:$/i.test(source)) return target.protocol === source.toLowerCase();
  const m = /^([a-z][a-z0-9+.-]*):\/\/([^:/]+)(?::(\*|\d+))?$/i.exec(source);
  if (!m) return false;
  const [, scheme, host, port] = m;
  return `${scheme!.toLowerCase()}:` === target.protocol && host === target.hostname && (port === "*" || port === target.port);
}

describe("the app's Content-Security-Policy", () => {
  it("runs the bundle's own files and nothing else", () => {
    const p = policy();
    expect(p["default-src"]).toEqual(["'self'"]);
    expect(p["script-src"]).toEqual(["'self'"]);
    // Both fall back to `script-src`; naming either would be a second, looser answer.
    expect(p["script-src-elem"]).toBeUndefined();
    expect(p["script-src-attr"]).toBeUndefined();
    for (const [directive, sources] of Object.entries(p)) {
      for (const source of sources) {
        expect(["'unsafe-inline'", "'unsafe-eval'", "'wasm-unsafe-eval'", "'unsafe-hashes'", "*"], `${directive} ${source}`).not.toContain(source);
        expect(source, `${directive} allows a nonce or a hash`).not.toMatch(/^'(nonce|sha\d+)-/);
      }
    }
  });

  it("is not framed, embeds no plugin, has no base to rewrite and posts forms only home", () => {
    const p = policy();
    expect(p["frame-ancestors"]).toEqual(["'none'"]);
    expect(p["object-src"]).toEqual(["'none'"]);
    expect(p["base-uri"]).toEqual(["'none'"]);
    expect(p["form-action"]).toEqual(["'self'"]);
  });

  it("takes styles, fonts and images from the bundle", () => {
    const p = policy();
    expect(p["style-src"]).toEqual(["'self'"]);
    expect(p["font-src"]).toEqual(["'self'"]);
    expect(p["img-src"]).toEqual(["'self'"]);
  });

  it("connects to the plane, to this machine's daemon, and elsewhere only over TLS", () => {
    const sources = policy()["connect-src"]!;
    expect(sources).toEqual(["'self'", "ws://127.0.0.1:*", "https:", "wss:"]);

    const allowed = (url: string): boolean => sources.some((s) => admits(s, url));
    // The address the app dials for the daemon, on any port it was handed. Only that one:
    // `[::1]` cannot be written in a source list, and Chromium refuses it with an error.
    expect(allowed(daemonUrl({ port: 49_152 }))).toBe(true);
    expect(daemonUrl({ port: 1 })).toMatch(/^ws:\/\/127\.0\.0\.1:/);
    for (const source of sources) expect(source, "an IPv6 literal, which CSP has no grammar for").not.toContain("[");
    // A worker pod and the identity provider, which the deployment names.
    expect(allowed("wss://dev-0.workers.example.test/v1/socket")).toBe(true);
    expect(allowed("https://login.example.test/token")).toBe(true);
    // Plaintext anywhere but this machine is not a connection the app makes.
    expect(allowed("ws://dev-0.workers.example.test/v1/socket")).toBe(false);
    expect(allowed("http://collector.example.test/")).toBe(false);
    expect(allowed("ws://localhost:8765/v1/socket")).toBe(false);
  });

  it("is sent on every response, including the page and the assets that add headers of their own", () => {
    const include = "include /etc/nginx/troupe/headers.conf;";
    const conf = nginx.replace(/#.*$/gm, "");
    // nginx drops a block's inherited `add_header` lines in any block with one of its own.
    const block = /^\s*location\b([^{]*)\{([^}]*)\}/gm;
    expect(conf.replace(block, "")).toContain(include);
    const locations = [...conf.matchAll(block)];
    expect(locations.length).toBeGreaterThan(0);
    for (const [, where, body] of locations) {
      if (body!.includes("add_header")) expect(body, `location${where}`).toContain(include);
    }
    expect(conf).not.toMatch(/add_header\s+Content-Security-Policy/);
    // And the image puts the file where the include looks for it.
    expect(dockerfile).toMatch(/^COPY docker\/headers\.conf \/etc\/nginx\/troupe\/headers\.conf$/m);
  });

  it("is a policy the page can run under: its one script is a file, and nothing in it is inline", () => {
    const scripts = [...page.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
    expect(scripts).toHaveLength(1);
    for (const [, attributes, body] of scripts) {
      expect(body!.trim(), "an inline script").toBe("");
      expect(attributes).toMatch(/\bsrc="\/[^/]/);
    }
    expect(page).not.toMatch(/<style\b|\sstyle\s*=|\son[a-z]+\s*=|javascript:/i);
  });
});
