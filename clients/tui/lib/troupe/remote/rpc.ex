defmodule Troupe.Remote.RPC do
  @moduledoc """
  JSON-RPC 2.0 over one text frame per message: encoding, and classifying what
  comes back.

  The client answers server-to-client requests with `-32601` rather than
  ignoring them, as the contract says: a server waiting for an answer should
  find out now that this client has no methods, not time out.
  """

  @type incoming ::
          {:result, term(), term()}
          | {:error, term(), map()}
          | {:notification, String.t(), map()}
          | {:request, term(), String.t(), map()}
          | :ignore

  @doc "One request frame."
  @spec request(term(), String.t(), map()) :: iodata()
  def request(id, method, params) when is_binary(method) and is_map(params) do
    Jason.encode_to_iodata!(%{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  @doc "One notification frame (no id, no answer)."
  @spec notification(String.t(), map()) :: iodata()
  def notification(method, params) when is_binary(method) and is_map(params) do
    Jason.encode_to_iodata!(%{jsonrpc: "2.0", method: method, params: params})
  end

  @doc "The answer to a server-to-client request: method not found."
  @spec method_not_found(term()) :: iodata()
  def method_not_found(id) do
    Jason.encode_to_iodata!(%{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_601, message: "method not found"}
    })
  end

  @doc "Decodes and classifies one text frame."
  @spec decode(String.t()) :: incoming()
  def decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = message} -> classify(message)
      _ -> :ignore
    end
  end

  @doc "Classifies an already-decoded message."
  @spec classify(map()) :: incoming()
  def classify(%{"id" => id, "result" => result}), do: {:result, id, result}

  def classify(%{"id" => id, "error" => %{} = error}),
    do:
      {:error, id,
       %{
         code: error["code"],
         message: error["message"] || "",
         data: error["data"]
       }}

  def classify(%{"method" => method, "id" => id} = message) when is_binary(method),
    do: {:request, id, method, params(message)}

  def classify(%{"method" => method} = message) when is_binary(method),
    do: {:notification, method, params(message)}

  def classify(_message), do: :ignore

  defp params(%{"params" => %{} = params}), do: params
  defp params(_message), do: %{}

  # PROTOCOL.md §10: each code, and the token its `message` carries.
  @codes %{
    -32_700 => :parse_error,
    -32_600 => :invalid_request,
    -32_601 => :method_not_found,
    -32_602 => :invalid_params,
    -32_603 => :internal_error,
    -32_001 => :not_initialized,
    -32_002 => :unsupported_version,
    -32_003 => :unauthenticated,
    -32_004 => :forbidden,
    -32_005 => :not_found,
    -32_006 => :conflict,
    -32_007 => :stale_version,
    -32_008 => :capacity,
    -32_009 => :resync_required,
    -32_010 => :unavailable,
    -32_011 => :rate_limited,
    -32_012 => :payload_too_large,
    -32_013 => :consent_required,
    -32_014 => :budget_exhausted
  }

  @doc "The contract's error table (PROTOCOL.md §10): each code and its token."
  @spec codes() :: %{integer() => atom()}
  def codes, do: @codes

  @doc """
  The contract's error codes as the tokens PROTOCOL.md §10 gives them, so callers
  match on meaning rather than numbers. Anything else comes back as `{:rpc, code}`.
  """
  @spec reason(map()) :: atom() | {:rpc, integer() | nil}
  def reason(%{code: code}), do: Map.get(@codes, code, {:rpc, code})

  @doc """
  What to tell the user about a failed call. The contract's `message` is a token, not
  prose, and `data` says why (PROTOCOL.md §10): `conflict` on its own names a row of
  the table, and nobody can act on it. A server that words its message keeps its words.
  """
  @spec describe(map()) :: String.t()
  def describe(%{message: message} = error) when is_binary(message) and message != "" do
    reason = reason(error)
    worded = if message == token(reason), do: nil, else: message
    head = heading(reason) || if(worded, do: nil, else: message)
    line = [head, worded, cause(error)] |> Enum.reject(&is_nil/1) |> Enum.join(": ")

    if reason == :forbidden, do: line <> scope_hint(error), else: line
  end

  def describe(error), do: inspect(reason(error))

  defp token(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp token(_reason), do: nil

  defp heading(:unauthenticated), do: "signed out"
  defp heading(:forbidden), do: "not allowed"
  defp heading(:not_found), do: "not found"
  defp heading(:unavailable), do: "unavailable"
  defp heading(_reason), do: nil

  # The server puts the cause in `data.reason`, the part that failed in `component` and
  # what that part said in `detail`.
  defp cause(%{data: %{} = data}) do
    case Enum.filter([data["component"], data["reason"], data["detail"]], &said?/1) do
      [] -> nil
      said -> Enum.join(said, ": ")
    end
  end

  defp cause(_error), do: nil

  defp said?(value), do: is_binary(value) and value != ""

  # -32004 says which scope was missing when it can; saying so is the whole
  # point of the code.
  defp scope_hint(%{data: %{"scope" => scope}}) when is_binary(scope),
    do: " (needs the #{scope} scope)"

  defp scope_hint(%{data: %{"required_scope" => scope}}) when is_binary(scope),
    do: " (needs the #{scope} scope)"

  defp scope_hint(_error), do: ""

  @doc "A command id: one per user action, safe to repeat."
  @spec command_id() :: String.t()
  def command_id, do: "cmd_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
