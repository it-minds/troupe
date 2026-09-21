// The authorization code flow with PKCE — the sign-in a browser can actually do.
//
// The device grant is the right flow for a terminal and for a desktop shell, and it is
// what `AuthSession.signIn` uses. It does not work in a browser against every provider:
// Microsoft Entra sends no cross-origin headers on its `devicecode` endpoint, so a page
// asking it for a code is refused before the request is made, with no way to tell the
// page why. Entra *does* answer the token endpoint cross-origin, which is exactly what
// this flow needs.
//
// Nothing here is a second door into the plane. It is the same provider, the same id
// token and the same `/auth/exchange`; only the way the person proves who they are
// differs, and that is the provider's business rather than Troupe's.
//
// PKCE, not an implicit grant and not a client secret: a public client cannot keep a
// secret, so it proves instead that the code it is redeeming belongs to the request it
// started. The verifier never leaves this origin.

import { PlaneHttpError } from "./plane.js";
import type { Discovery, IdpTokens } from "./plane.js";

/** What the provider publishes about itself. Standard OIDC discovery. */
export interface IdpMetadata {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  device_authorization_endpoint?: string;
  end_session_endpoint?: string;
  [k: string]: unknown;
}

export interface PkcePair {
  verifier: string;
  challenge: string;
  method: "S256";
}

const UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

function randomString(length: number): string {
  const bytes = new Uint8Array(length);
  const crypto = globalThis.crypto;
  if (!crypto?.getRandomValues) throw new Error("no secure random source available");
  crypto.getRandomValues(bytes);
  let out = "";
  for (const b of bytes) out += UNRESERVED[b % UNRESERVED.length];
  return out;
}

function base64url(bytes: ArrayBuffer): string {
  let binary = "";
  for (const b of new Uint8Array(bytes)) binary += String.fromCharCode(b);
  const b64 = globalThis.btoa
    ? globalThis.btoa(binary)
    : (globalThis as { Buffer?: { from(s: string, e: string): { toString(e: string): string } } }).Buffer!.from(binary, "binary").toString("base64");
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A verifier of 64 unreserved characters and its S256 challenge. */
export async function pkcePair(): Promise<PkcePair> {
  const verifier = randomString(64);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(digest), method: "S256" };
}

/**
 * The provider's own metadata document.
 *
 * Asked of the provider rather than of the plane on purpose: `/.well-known/troupe`
 * names a device endpoint and a token endpoint because that is what the CLI needs, and
 * a plane that has never heard of this flow still works with it. Standard OIDC
 * discovery is the provider's contract, and Entra answers it cross-origin.
 */
export async function idpMetadata(discovery: Discovery, fetchImpl: typeof fetch = globalThis.fetch): Promise<IdpMetadata> {
  const published = discovery["authorization_endpoint"];
  if (typeof published === "string" && published) {
    return {
      issuer: discovery.issuer,
      authorization_endpoint: published,
      token_endpoint: discovery.token_endpoint,
      ...(discovery.device_authorization_endpoint ? { device_authorization_endpoint: discovery.device_authorization_endpoint } : {}),
    };
  }
  const url = `${discovery.issuer.replace(/\/+$/, "")}/.well-known/openid-configuration`;
  const res = await fetchImpl(url, { headers: { accept: "application/json" } });
  if (!res.ok) throw new PlaneHttpError("openid-configuration", res.status, await res.text());
  return (await res.json()) as IdpMetadata;
}

/** What has to survive the round trip through the provider, and nothing more. */
export interface PendingRedirect {
  verifier: string;
  state: string;
  redirectUri: string;
  tokenEndpoint: string;
  clientId: string;
  planeUrl: string;
}

/**
 * Where the pending flow is kept between leaving for the provider and coming back.
 *
 * `sessionStorage`, deliberately: it is scoped to this tab and cleared when the tab
 * closes, so an abandoned sign-in leaves nothing behind. The verifier is not a
 * credential for anything on its own — it is worthless without the authorization code,
 * which arrives in a URL this same tab is about to read.
 */
function pending(): Storage | null {
  try {
    return globalThis.sessionStorage ?? null;
  } catch {
    return null;
  }
}

const PENDING_KEY = "troupe.auth.pending";

export interface BeginRedirectOptions {
  discovery: Discovery;
  /** Must be registered with the provider, exactly. For Entra, as a *single-page* app. */
  redirectUri: string;
  planeUrl: string;
  scopes?: string[];
  fetchImpl?: typeof fetch;
  /** Entra shows an account picker with this; harmless elsewhere. */
  prompt?: "select_account" | "consent" | "login" | "none";
  /**
   * Which kind of account to offer. Left unset, this is inferred: an issuer that names
   * one Microsoft tenant can only ever admit that tenant's work accounts, so the picker
   * is told `organizations` and stops offering the personal Microsoft accounts the
   * browser happens to be signed in to. Pass a domain (`itminds.dk`) to skip the picker
   * entirely, or `null` to send no hint at all.
   */
  domainHint?: string | null;
  /** Extra provider-specific parameters. */
  extra?: Record<string, string>;
}

/**
 * Start the flow: returns the URL to send the person to. The caller navigates; this
 * function does not, so a shell can open a system browser instead of the current tab.
 */
export async function beginRedirect(opts: BeginRedirectOptions): Promise<{ url: string; state: string }> {
  const metadata = await idpMetadata(opts.discovery, opts.fetchImpl ?? globalThis.fetch);
  const { verifier, challenge, method } = await pkcePair();
  const state = randomString(32);

  const held: PendingRedirect = {
    verifier,
    state,
    redirectUri: opts.redirectUri,
    tokenEndpoint: metadata.token_endpoint,
    clientId: opts.discovery.client_id,
    planeUrl: opts.planeUrl,
  };
  const store = pending();
  if (!store) throw new Error("this host has no sessionStorage, so it cannot complete a redirect sign-in");
  store.setItem(PENDING_KEY, JSON.stringify(held));

  const url = new URL(metadata.authorization_endpoint);
  const hint = opts.domainHint === undefined ? inferredDomainHint(opts.discovery.issuer) : opts.domainHint;
  const params: Record<string, string> = {
    client_id: opts.discovery.client_id,
    response_type: "code",
    redirect_uri: opts.redirectUri,
    scope: (opts.scopes ?? opts.discovery.scopes).join(" "),
    state,
    code_challenge: challenge,
    code_challenge_method: method,
    // The id token is what `/auth/exchange` wants, and `response_mode: query` keeps the
    // code out of the fragment so it never reaches a referrer or a history entry twice.
    response_mode: "query",
    ...(opts.prompt ? { prompt: opts.prompt } : {}),
    ...(hint ? { domain_hint: hint } : {}),
    ...(opts.extra ?? {}),
  };
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  return { url: url.toString(), state };
}

/**
 * A Microsoft issuer that names a tenant rather than `common` admits that tenant's work
 * and school accounts and nothing else — a personal Microsoft account signing in there
 * fails after the password, which is the worst possible moment to find out. Telling the
 * picker so up front is the whole of this.
 *
 * Any other provider gets no hint: `domain_hint` is Microsoft's, and inventing a value
 * for a provider that ignores it would be guessing.
 */
function inferredDomainHint(issuer: string): string | null {
  try {
    const url = new URL(issuer);
    if (!/(^|\.)(login\.microsoftonline\.com|login\.microsoft\.com|sts\.windows\.net)$/i.test(url.hostname)) return null;
    const tenant = url.pathname.split("/").filter(Boolean)[0] ?? "";
    // `common` and `consumers` deliberately include personal accounts; leave them be.
    if (tenant === "" || tenant.toLowerCase() === "common" || tenant.toLowerCase() === "consumers") return null;
    return "organizations";
  } catch {
    return null;
  }
}

/** Whether the current URL looks like a provider sending somebody back. */
export function hasRedirectAnswer(href: string = globalThis.location?.href ?? ""): boolean {
  if (!href) return false;
  const params = new URL(href).searchParams;
  return (params.has("code") || params.has("error")) && params.has("state");
}

export interface RedirectResult {
  tokens: IdpTokens;
  planeUrl: string;
}

/**
 * One authorization code, one exchange — however many callers ask.
 *
 * Redeeming a code consumes the verifier, so a second caller for the same code would
 * find nothing stored and conclude the sign-in began somewhere else. That is not a
 * hypothetical: React's StrictMode runs an effect twice in development, and the second
 * run lands here while the first is still waiting on the provider. A remount, a fast
 * refresh, or two components both trying to be helpful do the same thing.
 *
 * So the work is keyed on the code and shared. The entry is kept — a resolved sign-in
 * stays resolved for anyone who asks again with the same code — because the alternative
 * is a caller who asks a moment too late being told its own successful sign-in never
 * happened. It is cleared when a different code arrives, which is the only time it
 * could grow.
 */
const inFlight = new Map<string, Promise<RedirectResult>>();

/**
 * Finish the flow from the URL the provider sent the person back to.
 *
 * Returns null when there is nothing to finish, so a page can call it unconditionally
 * on load. Throws when the provider reported an error, or when the state does not match
 * what this tab started — which is the whole point of the state.
 */
export async function completeRedirect(
  href: string = globalThis.location?.href ?? "",
  fetchImpl: typeof fetch = globalThis.fetch,
): Promise<RedirectResult | null> {
  if (!hasRedirectAnswer(href)) return null;
  const params = new URL(href).searchParams;

  // A refusal carries no code and nothing was spent, so it needs none of the machinery
  // below — and it must be reported every time it is asked about, not memoised.
  const error = params.get("error");
  if (error) throw new Error(`${error}: ${params.get("error_description") ?? "the identity provider refused the sign-in"}`);

  const code = params.get("code");
  if (!code) throw new Error("the identity provider sent no code");

  const already = inFlight.get(code);
  if (already) return already;
  inFlight.clear(); // a new code means every older one is finished with

  const attempt = redeem(code, params.get("state"), fetchImpl);
  inFlight.set(code, attempt);
  // A failure is not remembered: whatever went wrong, asking again should ask again.
  attempt.catch(() => inFlight.delete(code));
  return attempt;
}

async function redeem(code: string, state: string | null, fetchImpl: typeof fetch): Promise<RedirectResult> {
  const store = pending();
  const raw = store?.getItem(PENDING_KEY);
  if (!raw) throw new Error("this sign-in did not start in this browser, so it cannot be completed here");
  // Whether it succeeds or fails, this attempt is over: a verifier is used once.
  store?.removeItem(PENDING_KEY);
  const held = JSON.parse(raw) as PendingRedirect;

  if (state !== held.state) throw new Error("the sign-in came back with a state this browser did not send");

  const body = new URLSearchParams({
    client_id: held.clientId,
    grant_type: "authorization_code",
    code,
    redirect_uri: held.redirectUri,
    code_verifier: held.verifier,
  });
  const res = await fetchImpl(held.tokenEndpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body,
  });
  if (!res.ok) throw new PlaneHttpError("token", res.status, await res.text());
  return { tokens: (await res.json()) as IdpTokens, planeUrl: held.planeUrl };
}

/** Take the code and state off the address bar without adding a history entry. */
export function scrubRedirect(): void {
  const location = globalThis.location;
  const history = globalThis.history;
  if (!location || !history?.replaceState) return;
  const url = new URL(location.href);
  for (const key of ["code", "state", "error", "error_description", "session_state", "error_uri"]) {
    url.searchParams.delete(key);
  }
  history.replaceState({}, "", url.pathname + (url.search === "?" ? "" : url.search) + url.hash);
}
