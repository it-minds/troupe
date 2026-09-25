// Signing in, and staying signed in.
//
// Two credentials, with different lifetimes and different homes. The identity
// provider's *refresh token* is the long-lived one and the only thing that is
// persisted: in the operating system's credential store when a desktop shell provides
// one, in memory otherwise. The plane token it buys lasts fifteen minutes at most, and
// the pod tokens the plane mints last less; neither is ever written down.
//
// Providers rotate the refresh token on every use, so the new one replaces the old one
// the moment it arrives — a rotation that is not persisted is a sign-in lost.

import { PlaneClient, PlaneHttpError } from "./plane.js";
import type { DeviceAuthorization, Discovery, IdpTokens, PlaneCredential } from "./plane.js";
import { beginRedirect, completeRedirect, hasRedirectAnswer, scrubRedirect } from "./pkce.js";
import type { BeginRedirectOptions } from "./pkce.js";

/** Where the refresh token lives. The default keeps it in memory and nowhere else. */
export interface TokenStore {
  read(key: string): Promise<string | null>;
  write(key: string, value: string): Promise<void>;
  clear(key: string): Promise<void>;
}

export function memoryTokenStore(): TokenStore {
  const held = new Map<string, string>();
  return {
    read: async (k) => held.get(k) ?? null,
    write: async (k, v) => void held.set(k, v),
    clear: async (k) => void held.delete(k),
  };
}

/**
 * `localStorage`, for a browser build with no shell behind it.
 *
 * This is the weakest of the stores and the only one a plain browser can offer: it is
 * readable by script on the same origin. It is the reason the browser build says on the
 * connect screen that it is a browser, and the reason the desktop shell exists.
 */
export function webTokenStore(prefix = "troupe.auth."): TokenStore {
  return {
    async read(k) {
      try {
        return globalThis.localStorage?.getItem(prefix + k) ?? null;
      } catch {
        return null; // private mode, or storage disabled
      }
    },
    async write(k, v) {
      try {
        globalThis.localStorage?.setItem(prefix + k, v);
      } catch {
        /* nothing to do: the session simply will not survive a relaunch */
      }
    },
    async clear(k) {
      try {
        globalThis.localStorage?.removeItem(prefix + k);
      } catch {
        /* as above */
      }
    },
  };
}

export interface SignInProgress {
  /** Show these to the person and wait. */
  onDeviceCode?: (auth: DeviceAuthorization) => void;
  onStatus?: (message: string) => void;
}

/**
 * A browser refusing a cross-origin request tells the *page* almost nothing: `fetch`
 * rejects with a bare TypeError and the reason is in the console, not in the exception.
 * The plane's allowlist is the overwhelmingly likely cause, so say so, and say exactly
 * which origin has to be added rather than making somebody guess.
 */
export class PlaneUnreachableError extends Error {
  readonly planeUrl: string;
  readonly origin: string | null;

  constructor(planeUrl: string, origin: string | null, cause: unknown) {
    // A browser tells the page nothing about why a cross-origin request failed — the
    // reason is in a console it cannot read — so this cannot assert which of the two it
    // was. It names both, and names the origin, because the allowlist is the one a
    // person can do something about and guessing it wrong costs an afternoon.
    const where = origin
      ? `Either the plane is not reachable, or it does not allow this origin: a plane only answers a browser from an origin in its allowlist, and this build is served from ${origin}. Add ${origin} to TROUPE_CORS_ORIGINS on the plane and restart it.`
      : "This is not a browser, so it is not the origin allowlist; check the URL and that the plane is reachable.";
    super(`could not reach the plane at ${planeUrl}. ${where}`);
    this.name = "PlaneUnreachableError";
    this.planeUrl = planeUrl;
    this.origin = origin;
    this.cause = cause;
  }
}

/** The origin a browser will put on its requests, or null outside a browser. */
export function currentOrigin(): string | null {
  const o = (globalThis as { location?: { origin?: string } }).location?.origin;
  return typeof o === "string" && o !== "null" ? o : null;
}

/**
 * One caller at a time per name, then the next.
 *
 * Web Locks where the host has them, because they hold across every tab on the origin:
 * a browser that has just restarted brings two tabs back at the same moment. A host
 * without them — an origin that is not a secure context — still gets one at a time
 * within the page, which is what StrictMode's second effect and a remount need.
 */
const queues = new Map<string, Promise<unknown>>();

function exclusively<T>(name: string, f: () => Promise<T>): Promise<T> {
  const locks = (globalThis as { navigator?: { locks?: LockManager } }).navigator?.locks;
  if (locks?.request) return locks.request(name, () => f()) as Promise<T>;
  const mine = (queues.get(name) ?? Promise.resolve()).then(() => f());
  const settled = mine.then(
    () => undefined,
    () => undefined,
  );
  queues.set(name, settled);
  void settled.then(() => {
    if (queues.get(name) === settled) queues.delete(name);
  });
  return mine;
}

/**
 * Whether the token endpoint refused the token, as opposed to failing to answer. OAuth
 * says no with a 400 (`invalid_grant`) or a 401 (`invalid_client`); a 5xx or a 429 is
 * the provider having a bad minute, and the token is still good once it has passed.
 */
function refused(e: unknown): e is PlaneHttpError {
  return e instanceof PlaneHttpError && (e.status === 400 || e.status === 401);
}

/** What a token endpoint said, in its own words: the status, `error` and `error_description`. */
function providerSaid(e: PlaneHttpError): string {
  try {
    const { error, error_description: description } = JSON.parse(e.body) as { error?: unknown; error_description?: unknown };
    if (typeof error === "string") return `HTTP ${e.status} ${error}${typeof description === "string" ? `: ${description}` : ""}`;
  } catch {
    /* not JSON; the body as it came */
  }
  return `HTTP ${e.status}${e.body ? `: ${e.body.slice(0, 200)}` : ""}`;
}

/**
 * A `fetch` that fails before producing a response — the shape of a blocked
 * cross-origin request — is reported as one. An HTTP error is the plane answering, so
 * it is passed through untouched.
 */
async function reachable<T>(planeUrl: string, origin: string | null, f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof PlaneHttpError) throw e;
    if (e instanceof TypeError) throw new PlaneUnreachableError(planeUrl, origin, e);
    throw e;
  }
}

export interface AuthSessionOptions {
  planeUrl: string;
  store?: TokenStore;
  fetchImpl?: typeof fetch;
  /** Renew the plane token this many seconds before it expires. */
  renewMarginSeconds?: number;
  /**
   * The origin this client presents on its requests. Defaults to the browser's own,
   * and is worth passing when the caller supplies its own `fetchImpl` — the message a
   * blocked request turns into names this, and naming the wrong one is worse than
   * saying nothing.
   */
  origin?: string | null;
  /**
   * Force a sign-in flow instead of inferring one.
   *
   * The inference asks whether this looks like a browser, and a desktop webview looks
   * exactly like one — it has a `location` and Web Crypto — while having no redirect
   * worth coming back to: its origin is `tauri://localhost`, which no provider will
   * have registered. A host that knows what it is says so.
   */
  flow?: "redirect" | "device";
  /** For tests. */
  now?: () => number;
}

/**
 * One signed-in plane. Holds the discovery document, the refresh token (through the
 * store), and the current plane token; hands out a valid plane token on demand and
 * renews it when it is close to expiry.
 *
 * `restore()` is what a relaunch calls: it needs no interaction if the store still has
 * a refresh token the provider will honour.
 */
export class AuthSession {
  readonly plane: PlaneClient;
  readonly planeUrl: string;

  private readonly store: TokenStore;
  private readonly renewMargin: number;
  private readonly origin: string | null;
  private readonly now: () => number;
  private discovery: Discovery | null = null;
  private credential: PlaneCredential | null = null;
  private renewing: Promise<PlaneCredential> | null = null;
  private refusal: string | null = null;
  private readonly forcedFlow: "redirect" | "device" | null;

  constructor(opts: AuthSessionOptions) {
    this.planeUrl = opts.planeUrl.replace(/\/+$/, "");
    this.plane = new PlaneClient(this.planeUrl, opts.fetchImpl ?? globalThis.fetch);
    this.store = opts.store ?? memoryTokenStore();
    this.renewMargin = opts.renewMarginSeconds ?? 120;
    this.origin = opts.origin === undefined ? currentOrigin() : opts.origin;
    this.now = opts.now ?? (() => Date.now());
    this.forcedFlow = opts.flow ?? null;
  }

  /** The key the refresh token is stored under; one per plane, so two are independent. */
  private get key(): string {
    return `refresh:${this.planeUrl}`;
  }

  get signedIn(): boolean {
    return this.credential !== null;
  }

  /** What the plane said about the person at the last exchange. */
  get me(): PlaneCredential | null {
    return this.credential;
  }

  async discover(): Promise<Discovery> {
    if (!this.discovery) this.discovery = await reachable(this.planeUrl, this.origin, () => this.plane.discover());
    return this.discovery;
  }

  /**
   * Which sign-in this host can do.
   *
   * A browser gets the redirect: the device grant needs the provider's device endpoint
   * to answer a cross-origin request, and Microsoft Entra does not — a page asking for
   * a code is refused before the request leaves, with no way to tell the page why.
   * Anything that is not a browser has no redirect to come back from and uses the
   * device grant, which is what it is for.
   */
  get preferredFlow(): "redirect" | "device" {
    if (this.forcedFlow) return this.forcedFlow;
    const hasLocation = typeof (globalThis as { location?: { href?: string } }).location?.href === "string";
    return hasLocation && Boolean(globalThis.crypto?.subtle) ? "redirect" : "device";
  }

  /**
   * Leave for the identity provider. Resolves with the URL to go to; the caller
   * navigates, so a desktop shell can open a system browser instead of this tab.
   */
  async beginRedirectSignIn(
    opts: Omit<BeginRedirectOptions, "discovery" | "planeUrl" | "redirectUri"> & { redirectUri?: string } = {},
  ): Promise<{ url: string; state: string }> {
    const discovery = await this.discover();
    const redirectUri = opts.redirectUri ?? (globalThis as { location?: { origin?: string } }).location?.origin;
    if (!redirectUri) throw new Error("no redirect URI, and no origin to infer one from");
    return beginRedirect({ ...opts, fetchImpl: opts.fetchImpl ?? this.plane.http, discovery, planeUrl: this.planeUrl, redirectUri });
  }

  /** Is the current URL a provider sending somebody back? Safe to call on every load. */
  static get returning(): boolean {
    return hasRedirectAnswer();
  }

  /**
   * Finish a redirect sign-in. Returns null when there is nothing to finish, so a page
   * can call it unconditionally. The code and state come off the address bar either
   * way — a failed sign-in that leaves them there would retry itself on every reload.
   */
  async completeRedirectSignIn(): Promise<PlaneCredential | null> {
    if (!hasRedirectAnswer()) return null;
    try {
      const answer = await completeRedirect(undefined, this.plane.http);
      if (!answer) return null;
      return await this.adopt(answer.tokens);
    } finally {
      scrubRedirect();
    }
  }

  /** Sign in with the device grant. Resolves once the person has approved. */
  async signIn(progress: SignInProgress = {}, signal?: AbortSignal): Promise<PlaneCredential> {
    const d = await this.discover();
    progress.onStatus?.("asking the identity provider for a code…");
    const auth = await reachable(this.planeUrl, this.origin, () => this.plane.startDeviceFlow(d));
    progress.onDeviceCode?.(auth);
    progress.onStatus?.("waiting for you to approve the sign-in…");
    const tokens = await this.plane.pollDeviceFlow(d, auth, signal ? { signal } : {});
    return this.adopt(tokens);
  }

  /**
   * Sign in from what the store already holds. Returns null when there is nothing
   * stored or the provider has stopped honouring it — in which case the stored token
   * is thrown away, because a refresh token that has been refused will not recover.
   * A provider that fails to answer has refused nothing, so that throws and the token
   * stays for the next attempt.
   */
  async restore(): Promise<PlaneCredential | null> {
    const tokens = await this.refreshStored();
    return tokens ? this.enter(tokens) : null;
  }

  /**
   * Trade the stored refresh token for fresh tokens, and store the one it rotated to.
   *
   * One caller at a time per plane. The provider rotates the token on every use and
   * refuses the old one from then on, so two callers that read the same token — React's
   * StrictMode running the load effect twice, a remount, two tabs coming back at once —
   * would have one of them refused, and the refused one would clear the store, taking
   * the token the other had just been given with it: a reload that signs the person out.
   * Inside the lock the token is read afresh, so whoever goes second spends the one the
   * first was given.
   */
  private refreshStored(): Promise<IdpTokens | null> {
    return exclusively(`troupe.auth.${this.key}`, async () => {
      const refresh = await this.store.read(this.key);
      if (!refresh) return null;
      const d = await this.discover();
      let tokens: IdpTokens;
      try {
        tokens = await reachable(this.planeUrl, this.origin, () => this.plane.refreshIdp(d, refresh));
      } catch (e) {
        if (!refused(e)) throw e; // the plane, the network, or a provider that did not answer
        // Said out loud, because the only other trace is the sign-in screen, and that
        // looks the same whatever the provider's reason was.
        this.refusal = providerSaid(e);
        console.warn(`troupe: the identity provider refused the stored sign-in for ${this.planeUrl}, so it has been forgotten (${this.refusal})`);
        // Only the token that was refused: anything else in the store now was put there
        // since, by a sign-in or a tab that does not share this lock.
        if ((await this.store.read(this.key)) === refresh) await this.store.clear(this.key);
        return null;
      }
      this.refusal = null;
      if (tokens.refresh_token) await this.store.write(this.key, tokens.refresh_token);
      return tokens;
    });
  }

  /** Forget the refresh token and the plane token. The provider's session is its own. */
  async signOut(): Promise<void> {
    this.credential = null;
    await this.store.clear(this.key);
  }

  /**
   * A plane token good for at least the renewal margin, renewed from the stored refresh
   * token if the one in hand is close to running out. Concurrent callers share one
   * renewal rather than racing the provider's rotation.
   */
  async token(): Promise<string> {
    const c = this.credential;
    if (c && c.expires_at * 1000 - this.now() > this.renewMargin * 1000) return c.token;
    if (this.renewing) return (await this.renewing).token;
    this.renewing = this.renew().finally(() => {
      this.renewing = null;
    });
    return (await this.renewing).token;
  }

  private async renew(): Promise<PlaneCredential> {
    const restored = await this.restore();
    if (restored) return restored;
    const why = this.refusal ? ` (${this.refusal})` : "";
    throw new Error(`signed out: the identity provider would not renew this session${why}`);
  }

  /** A sign-in's tokens: persist the refresh token, then exchange for a plane token. */
  private async adopt(tokens: IdpTokens): Promise<PlaneCredential> {
    if (!(tokens.id_token ?? tokens.access_token)) throw new Error("the identity provider returned no id token");
    // Persisted before the exchange: a rotated refresh token that is dropped because
    // the exchange failed would lock the person out until they signed in again.
    if (tokens.refresh_token) {
      await this.store.write(this.key, tokens.refresh_token);
    } else {
      // A sign-in that ends at the next reload, and nothing else would say so. Entra
      // and Authentik issue a refresh token only for `offline_access`, and Authentik
      // only when the provider's own scope list carries it as well.
      console.warn(`troupe: the identity provider issued no refresh token for ${this.planeUrl}, so a reload will ask for a sign-in again. Its scopes need "offline_access", allowed for this client.`);
    }
    return this.enter(tokens);
  }

  /** Exchange the provider's id token for a plane token. */
  private async enter(tokens: IdpTokens): Promise<PlaneCredential> {
    const idToken = tokens.id_token ?? tokens.access_token;
    if (!idToken) throw new Error("the identity provider returned no id token");
    const credential = await reachable(this.planeUrl, this.origin, () => this.plane.exchange(idToken));
    this.credential = credential;
    return credential;
  }

  /** One authenticated plane call, with the token renewed first if it is due. */
  async rpc<T = unknown>(method: string, params: unknown = {}): Promise<T> {
    const token = await this.token();
    return reachable(this.planeUrl, this.origin, () => this.plane.rpc<T>(token, method, params));
  }
}
