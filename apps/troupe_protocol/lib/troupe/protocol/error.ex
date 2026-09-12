defmodule Troupe.Protocol.Error do
  @moduledoc """
  The error table from `PROTOCOL.md` §9.

  `message` is a stable machine-readable token rather than prose, so a client can
  branch on it without parsing English. Human wording belongs in the client.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :data]

  @type t :: %__MODULE__{code: integer(), message: String.t(), data: map() | nil}

  @codes %{
    parse_error: -32_700,
    invalid_request: -32_600,
    method_not_found: -32_601,
    invalid_params: -32_602,
    internal_error: -32_603,
    not_initialized: -32_001,
    unsupported_version: -32_002,
    unauthenticated: -32_003,
    forbidden: -32_004,
    not_found: -32_005,
    conflict: -32_006,
    stale_version: -32_007,
    capacity: -32_008,
    resync_required: -32_009,
    unavailable: -32_010,
    rate_limited: -32_011,
    payload_too_large: -32_012,
    # Stage 4: a client-hosted tool may not be registered on somebody else's behalf.
    # `data` carries the challenge to show them and the tools it covers.
    consent_required: -32_013,
    # A team's budget has nothing left to reserve for a new session. Distinct from
    # `capacity`, which is about pods: one is money, the other is room.
    budget_exhausted: -32_014
  }

  @doc "Every error token and its code, for documentation and schema generation."
  @spec codes() :: %{atom() => integer()}
  def codes, do: @codes

  @doc """
  Build an error.

      iex> Troupe.Protocol.Error.new(:forbidden, %{required_scope: "control"})
      %Troupe.Protocol.Error{code: -32004, message: "forbidden", data: %{required_scope: "control"}}
  """
  @spec new(atom(), map() | nil) :: t()
  def new(token, data \\ nil) when is_map_key(@codes, token) do
    %__MODULE__{code: @codes[token], message: Atom.to_string(token), data: data}
  end

  @doc "The token for a code, or `:unknown`."
  @spec token(integer()) :: atom()
  def token(code) do
    Enum.find_value(@codes, :unknown, fn {token, value} -> if value == code, do: token end)
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{data: nil} = error),
    do: %{"code" => error.code, "message" => error.message}

  def to_json(%__MODULE__{} = error) do
    %{"code" => error.code, "message" => error.message, "data" => error.data}
  end

  @spec from_json(map()) :: t()
  def from_json(%{"code" => code, "message" => message} = json) do
    %__MODULE__{code: code, message: message, data: Map.get(json, "data")}
  end
end
