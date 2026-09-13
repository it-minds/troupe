// A fake identity provider: the device authorization grant, and nothing else.
//
// It is deliberately awkward in the two ways a real one is — it makes the client wait
// with `authorization_pending`, and it rotates the refresh token on every use — because
// both are things a client gets wrong silently and only notices a day later when
// somebody has to sign in again.

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

interface Grant {
  deviceCode: string;
  userCode: string;
  subject: string;
  displayName: string;
  approved: boolean;
  pollsBeforeApproval: number;
  polls: number;
}

export class FakeIdp {
  readonly server: Server;
  /** Refresh tokens that are still live, mapped to the subject they belong to. */
  readonly refreshTokens = new Map<string, { subject: string; displayName: string }>();
  /** Every refresh token ever issued, so a test can prove an old one stops working. */
  readonly issued: string[] = [];
  /** Ask the client to slow down on the first poll of the flow. */
  slowDownOnce = false;
  /**
   * Origins a browser may read this provider's answers from.
   *
   * A browser client needs the *provider* to allow its origin as well as the plane —
   * the device grant is spoken to the provider directly, so a deployment that allows
   * the GUI at the plane and forgets the provider fails at the second step. A real
   * provider calls this the public client's allowed web origins.
   */
  corsOrigins: string[] = [];

  private readonly grants = new Map<string, Grant>();
  private counter = 0;
  private url = "";

  private constructor() {
    this.server = createServer((req, res) => void this.handle(req, res));
  }

  static async start(): Promise<FakeIdp> {
    const idp = new FakeIdp();
    await new Promise<void>((r) => idp.server.listen(0, "127.0.0.1", r));
    const { port } = idp.server.address() as AddressInfo;
    idp.url = `http://127.0.0.1:${port}`;
    return idp;
  }

  get issuer(): string {
    return this.url;
  }

  get deviceAuthorizationEndpoint(): string {
    return `${this.url}/device/code`;
  }

  get tokenEndpoint(): string {
    return `${this.url}/token`;
  }

  /** Approve whatever flow is waiting, as `subject`. What the person does in a browser. */
  approve(subject = "alice@example.com", displayName = "Alice"): void {
    for (const g of this.grants.values()) {
      g.subject = subject;
      g.displayName = displayName;
      g.approved = true;
    }
  }

  /** Stop honouring a refresh token, the way a revoked session would be. */
  revoke(token: string): void {
    this.refreshTokens.delete(token);
  }

  async stop(): Promise<void> {
    await new Promise<void>((r) => this.server.close(() => r()));
  }

  private async handle(req: import("node:http").IncomingMessage, res: import("node:http").ServerResponse): Promise<void> {
    const body = await readBody(req);
    const form = new URLSearchParams(body);
    const origin = (req.headers["origin"] as string | undefined) ?? null;
    const headers: Record<string, string> = { "content-type": "application/json", vary: "origin" };
    if (origin && this.corsOrigins.includes(origin)) {
      headers["access-control-allow-origin"] = origin;
      headers["access-control-allow-headers"] = "content-type";
      headers["access-control-allow-methods"] = "POST, OPTIONS";
    }
    if (req.method === "OPTIONS") {
      res.writeHead(204, headers);
      res.end();
      return;
    }
    const json = (status: number, payload: unknown) => {
      res.writeHead(status, headers);
      res.end(JSON.stringify(payload));
    };

    if (req.url?.startsWith("/device/code")) {
      this.counter += 1;
      const grant: Grant = {
        deviceCode: `dc-${this.counter}`,
        userCode: `WXYZ-${this.counter}`,
        subject: "",
        displayName: "",
        approved: false,
        pollsBeforeApproval: 0,
        polls: 0,
      };
      this.grants.set(grant.deviceCode, grant);
      return json(200, {
        device_code: grant.deviceCode,
        user_code: grant.userCode,
        verification_uri: `${this.url}/device`,
        verification_uri_complete: `${this.url}/device?code=${grant.userCode}`,
        // A tenth of a second, so the tests are not a study in patience. The client
        // honours whatever it is told, which is the behaviour under test.
        interval: 0.1,
        expires_in: 30,
      });
    }

    if (req.url?.startsWith("/token")) {
      const grantType = form.get("grant_type");

      if (grantType === "refresh_token") {
        const old = form.get("refresh_token") ?? "";
        const held = this.refreshTokens.get(old);
        if (!held) return json(400, { error: "invalid_grant" });
        // Rotation: the old one stops working the instant the new one is issued.
        this.refreshTokens.delete(old);
        return json(200, this.mint(held.subject, held.displayName));
      }

      const grant = this.grants.get(form.get("device_code") ?? "");
      if (!grant) return json(400, { error: "invalid_grant" });
      grant.polls += 1;
      if (this.slowDownOnce && grant.polls === 1) return json(400, { error: "slow_down" });
      if (!grant.approved) return json(400, { error: "authorization_pending" });
      this.grants.delete(grant.deviceCode);
      return json(200, this.mint(grant.subject, grant.displayName));
    }

    json(404, { error: "not_found" });
  }

  private mint(subject: string, displayName: string): Record<string, unknown> {
    const refresh = `rt-${subject}-${this.issued.length + 1}`;
    this.refreshTokens.set(refresh, { subject, displayName });
    this.issued.push(refresh);
    // An id token the fake plane can read. Not signed: the plane in these tests verifies
    // nothing, because what is under test is the client, and a real plane's verification
    // is tested where it lives.
    const id = Buffer.from(JSON.stringify({ sub: subject, name: displayName })).toString("base64url");
    return { id_token: `fake.${id}.sig`, refresh_token: refresh, expires_in: 300, token_type: "Bearer" };
  }
}

export function readBody(req: import("node:http").IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let s = "";
    req.on("data", (c) => (s += c));
    req.on("end", () => resolve(s));
  });
}

export function subjectOfIdToken(idToken: string): { sub: string; name: string } {
  const part = idToken.split(".")[1] ?? "";
  return JSON.parse(Buffer.from(part, "base64url").toString()) as { sub: string; name: string };
}
