// Troupe protocol v1 — the shapes a client sees. Mirrors PROTOCOL.md; additive-only
// within the major version, so every object type here is open (`[k: string]: unknown`).

export type JsonRpcId = number | string;

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: JsonRpcId;
  method: string;
  params?: unknown;
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export interface JsonRpcError {
  code: number;
  message: string;
  data?: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result?: unknown;
  error?: JsonRpcError;
}

export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

/** Error `message` tokens from PROTOCOL.md §10. */
export const ErrorCodes = {
  parse_error: -32700,
  invalid_request: -32600,
  method_not_found: -32601,
  invalid_params: -32602,
  internal_error: -32603,
  not_initialized: -32001,
  unsupported_version: -32002,
  unauthenticated: -32003,
  forbidden: -32004,
  not_found: -32005,
  conflict: -32006,
  stale_version: -32007,
  capacity: -32008,
  resync_required: -32009,
  unavailable: -32010,
  rate_limited: -32011,
  payload_too_large: -32012,
  consent_required: -32013,
} as const;

export type Scope = "observe" | "control" | "admin";

export interface Principal {
  subject: string;
  display_name?: string;
  kind: string;
  [k: string]: unknown;
}

export interface InitializeResult {
  protocol_version: string;
  server_info: { name: string; version: string; instance_id: string; [k: string]: unknown };
  capabilities: Record<string, unknown>;
  principal: Principal;
  scopes: Scope[];
  limits?: { max_message_bytes?: number; outbound_queue?: number; [k: string]: unknown };
  auth?: { expires_at?: number; [k: string]: unknown };
  [k: string]: unknown;
}

export interface Actor {
  subject?: string;
  kind: string;
  [k: string]: unknown;
}

/** A persisted, hash-chained event (PROTOCOL.md §4, "Durable events"). */
export interface DurableEvent {
  seq: number;
  prev_hash: string | null;
  ts: string;
  actor: Actor;
  agent: string[];
  type: string;
  v: number;
  data: Record<string, unknown>;
  ephemeral?: false;
  [k: string]: unknown;
}

/** Never persisted, may be dropped under load. */
export interface EphemeralEvent {
  ephemeral: true;
  type: string;
  agent: string[];
  data: Record<string, unknown>;
  [k: string]: unknown;
}

export type TroupeEvent = DurableEvent | EphemeralEvent;

export function isDurable(e: TroupeEvent): e is DurableEvent {
  return typeof (e as DurableEvent).seq === "number";
}

export interface EventEnvelope {
  topic: string;
  session_id?: string;
  event: TroupeEvent;
  [k: string]: unknown;
}

export interface LlmDeltaData {
  kind: "text" | "thinking" | "tool_use" | string;
  text?: string;
  fragment?: string;
  id?: string;
  name?: string;
  [k: string]: unknown;
}

export interface SessionSummary {
  id: string;
  workspace: string;
  branch?: string | null;
  profile?: string;
  state: "active" | "dormant" | "read_only" | "erased" | string;
  status?: string;
  tokens?: number;
  cost?: number;
  created_at?: string;
  last_active_at?: string;
  pinned?: boolean;
  [k: string]: unknown;
}

export interface SubscribeResult {
  subscription_id: string;
  head_seq: number;
  [k: string]: unknown;
}

export interface SessionCreateResult {
  session_id: string;
  workspace: string;
  worktree?: string | null;
  branch?: string | null;
  [k: string]: unknown;
}

export interface ResyncRequired {
  subscription_id: string;
  topic: string;
  last_seq: number;
}

export interface AuthExpiring {
  expires_at: number;
}

/** A server → client request the client must answer (client-hosted tools, §8). */
export interface ToolInvoke {
  call_id: string;
  session_id?: string;
  name: string;
  args: Record<string, unknown>;
  [k: string]: unknown;
}

export interface BlobResponse {
  blob: string;
  size: number;
  /** Inclusive, and possibly shorter than the one asked for: the server caps a response. */
  range?: [number, number];
  encoding: "base64" | string;
  data: string;
  [k: string]: unknown;
}

export interface FsEntry {
  path: string;
  name: string;
  kind: "file" | "directory" | "other" | string;
  size: number;
  [k: string]: unknown;
}

export interface FsListing {
  path: string;
  entries: FsEntry[];
  [k: string]: unknown;
}

export interface FsFile {
  path: string;
  content: string;
  size: number;
  /** `sha256:…`, the same hash `fs_changed` carries. */
  hash: string;
  [k: string]: unknown;
}
