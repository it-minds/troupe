// What a plane signs for its clients, and how this client checks it (#657).
//
// The twin of `Troupe.Protocol.PlaneSignature`, held to the same vector
// (`test/plane-signature.test.ts`). A plane signs its version policy (`me.client_versions`)
// and its organisation's document (`me.client_defaults`) with an Ed25519 key of its own in
// OpenBao, which nothing can export. Each answer carries `signed`: the canonical JSON that
// was signed, as text, and the signature over those bytes. The text is checked as it came
// and parsed afterwards, so this side never has to encode it the way the plane did.
//
// The key a client checks against is the one this machine pinned for the plane at sign-in,
// which the daemon keeps (`identity.get`'s `plane_key`); the plane's own fingerprint label
// is read only to say which other key signed an answer the pinned one did not.

/** A plane's key as it is served and pinned: base64 of the 32 bytes, and its fingerprint. */
export interface PlaneKey {
  algorithm: "ed25519" | string;
  public_key: string;
  fingerprint: string;
}

/** The `signed` a plane's answer carries. */
export interface SignedAnswer {
  algorithm: "ed25519" | string;
  fingerprint: string;
  document: string;
  signature: string;
}

/** What a plane signs. */
export type SignedKind = "client_versions" | "client_defaults";

export type SignatureRefusal =
  | { reason: "unsigned" }
  | { reason: "malformed" }
  | { reason: "forged" }
  | { reason: "other_key"; fingerprint: string }
  | { reason: "expired"; at: string }
  | { reason: "wrong_kind"; kind: string };

export type Verified<T> = { ok: true; body: T; signedAt: string; expiresAt: string } | ({ ok: false } & SignatureRefusal);

function bytes(base64: string): Uint8Array<ArrayBuffer> | null {
  try {
    const text = atob(base64);
    const out = new Uint8Array(new ArrayBuffer(text.length));
    for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function base64(data: ArrayBuffer): string {
  let text = "";
  for (const b of new Uint8Array(data)) text += String.fromCharCode(b);
  return btoa(text);
}

/** A key's fingerprint, `SHA256:` and the unpadded base64 of its SHA-256, as the plane writes it. */
export async function fingerprintOf(publicKey: string): Promise<string | null> {
  const raw = bytes(publicKey);
  if (!raw || raw.length !== 32) return null;
  const digest = await crypto.subtle.digest("SHA-256", raw);
  return `SHA256:${base64(digest).replace(/=+$/, "")}`;
}

async function holds(document: string, signature: Uint8Array<ArrayBuffer>, publicKey: Uint8Array<ArrayBuffer>): Promise<boolean> {
  const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
  return crypto.subtle.verify({ name: "Ed25519" }, key, signature, new TextEncoder().encode(document));
}

/**
 * Check an answer's `signed` against the key pinned for its plane, as `kind`: the body the
 * plane signed, or why not, as `Troupe.Protocol.PlaneSignature.verify/4` says it.
 */
export async function verifySigned<T = Record<string, unknown>>(
  signed: SignedAnswer | null | undefined,
  pinned: PlaneKey,
  kind: SignedKind,
  now: Date = new Date(),
): Promise<Verified<T>> {
  if (!signed) return { ok: false, reason: "unsigned" };
  if (signed.algorithm !== "ed25519" || typeof signed.document !== "string" || typeof signed.signature !== "string") {
    return { ok: false, reason: "malformed" };
  }
  const signature = bytes(signed.signature);
  const publicKey = bytes(pinned.public_key);
  if (!signature || signature.length !== 64 || !publicKey || publicKey.length !== 32) return { ok: false, reason: "malformed" };

  let ok: boolean;
  try {
    ok = await holds(signed.document, signature, publicKey);
  } catch {
    return { ok: false, reason: "malformed" };
  }
  if (!ok) {
    return typeof signed.fingerprint === "string" && signed.fingerprint !== pinned.fingerprint
      ? { ok: false, reason: "other_key", fingerprint: signed.fingerprint }
      : { ok: false, reason: "forged" };
  }

  let parsed: { kind?: unknown; body?: unknown; signed_at?: unknown; expires_at?: unknown };
  try {
    parsed = JSON.parse(signed.document) as typeof parsed;
  } catch {
    return { ok: false, reason: "malformed" };
  }
  if (!parsed.body || typeof parsed.body !== "object") return { ok: false, reason: "malformed" };
  if (parsed.kind !== kind) return typeof parsed.kind === "string" ? { ok: false, reason: "wrong_kind", kind: parsed.kind } : { ok: false, reason: "malformed" };
  const expires = typeof parsed.expires_at === "string" ? new Date(parsed.expires_at) : null;
  if (!expires || Number.isNaN(expires.getTime())) return { ok: false, reason: "malformed" };
  if (now.getTime() >= expires.getTime()) return { ok: false, reason: "expired", at: parsed.expires_at as string };
  return { ok: true, body: parsed.body as T, signedAt: String(parsed.signed_at), expiresAt: parsed.expires_at as string };
}

/**
 * What a refusal says, finishing "... is not taken", as the terminal and the daemon say it:
 * `what` is what was refused, `plane` where from, `pinned` the key held for it.
 */
export function refusalSentence(refusal: SignatureRefusal, plane: string, what: string, pinned: string): string {
  switch (refusal.reason) {
    case "unsigned":
      return `${what} from ${plane} is not signed, and this machine holds the plane's signing key ${pinned}: it is not taken`;
    case "other_key":
      return `${what} from ${plane} is signed by the key ${refusal.fingerprint}, not by ${pinned}, the key this machine pinned for that plane: it is not taken until you accept the new key`;
    case "forged":
      return `${what} from ${plane} does not match its signature: it was changed after the plane signed it, and is not taken`;
    case "expired":
      return `${what} from ${plane} was the plane's word until ${refusal.at}: it is not taken`;
    case "wrong_kind":
      return `${what} from ${plane} is signed as ${refusal.kind}, which is something else: it is not taken`;
    case "malformed":
      return `${what} from ${plane} carries a signature this client cannot read: it is not taken`;
  }
}
