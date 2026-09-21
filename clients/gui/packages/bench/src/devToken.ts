// Mint a worker session token locally, for benchmarking a standalone worker whose
// JWKS we control. In production the plane mints these through OpenBao transit; a
// client never signs its own. Claims and header mirror the plane's `Tokens` module:
// ES256, `kid` = RFC 7638 thumbprint, `aud` = the pod's worker id, `exp - iat <= 900`.

import { createHash, createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

export interface DevSigningKey {
  jwk: JsonWebKey & { kid?: string };
  kid: string;
}

export function loadSigningKey(path: string): DevSigningKey {
  const jwk = JSON.parse(readFileSync(path, "utf8")) as JsonWebKey & { kid?: string };
  const canonical = JSON.stringify({ crv: jwk.crv, kty: jwk.kty, x: jwk.x, y: jwk.y });
  const kid = jwk.kid ?? createHash("sha256").update(canonical).digest("base64url");
  return { jwk, kid };
}

export function mintWorkerToken(
  key: DevSigningKey,
  claims: { sub: string; aud: string; role?: "owner" | "collaborator" | "viewer"; session_id?: string; team?: string },
  lifetimeSeconds = 900,
): string {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", typ: "JWT", kid: key.kid };
  const payload = {
    sub: claims.sub,
    name: claims.sub,
    aud: claims.aud,
    role: claims.role ?? "owner",
    ...(claims.session_id ? { session_id: claims.session_id } : {}),
    ...(claims.team ? { team: claims.team } : {}),
    iat: now,
    nbf: now - 5,
    exp: now + Math.min(lifetimeSeconds, 900),
    jti: b64url(createHash("sha256").update(`${now}-${Math.random()}`).digest()).slice(0, 22),
  };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const privateKey = createPrivateKey({ key: key.jwk as never, format: "jwk" });
  const signature = sign("sha256", Buffer.from(signingInput), { key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${b64url(signature)}`;
}
