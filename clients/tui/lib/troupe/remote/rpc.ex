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

  @doc """
  The contract's error codes as atoms, so callers match on meaning rather than
  numbers. Anything else comes back as `{:rpc, code}`.
  """
  @spec reason(map()) :: atom() | {:rpc, integer() | nil}
  def reason(%{code: -32_001}), do: :unauthorized

  # The deployment this was built against answers an unauthenticated call with
  # -32003 and a `reason` naming the token problem. The contract reserves -32003
  # for a missing scope, so the two are told apart by that field: a token
  # problem is refreshed, a scope problem is explained (Decision 81).
  def reason(%{code: -32_003, data: %{"reason" => reason}})
      when reason in ~w(no_token bad_signature expired expired_token invalid_token unauthenticated),
      do: :unauthorized

  def reason(%{code: -32_003}), do: :forbidden
  def reason(%{code: -32_004}), do: :not_found
  def reason(%{code: -32_009}), do: :conflict
  def reason(%{code: -32_010}), do: :no_capacity
  def reason(%{code: -32_012}), do: :session_moved
  def reason(%{code: -32_601}), do: :method_not_found
  def reason(%{code: code}), do: {:rpc, code}

  @doc "What to tell the user about a failed call."
  @spec describe(map()) :: String.t()
  def describe(%{message: message} = error) when is_binary(message) and message != "" do
    case reason(error) do
      :unauthorized -> "signed out: #{message}"
      :forbidden -> "not allowed: #{message}" <> scope_hint(error)
      :no_capacity -> "no capacity: #{message}"
      :conflict -> "conflict: #{message}"
      :not_found -> "not found: #{message}"
      _ -> message
    end
  end

  def describe(error), do: inspect(reason(error))

  # -32003 says which scope was missing when it can; saying so is the whole
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
