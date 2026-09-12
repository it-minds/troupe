defmodule Troupe.A2A.Error do
  @moduledoc """
  The A2A error table, and how a plane error becomes one of them.

  A2A is JSON-RPC 2.0 with its own codes in the `-32000` block. They overlap Troupe's
  own — Troupe's `not_found` is `-32005`, which in A2A means "content type not
  supported" — so a plane error is never passed through by number. The ones the
  mapping can name are named; the rest keep the plane's token as the message, in the
  implementation-defined range, so a caller reading the log can still tell what the
  plane said.
  """

  alias Troupe.Protocol.Error, as: PlaneError

  @type t :: %{required(String.t()) => term()}

  @doc "A JSON-RPC error object."
  @spec new(integer(), String.t(), map() | nil) :: t()
  def new(code, message, data \\ nil)
  def new(code, message, nil), do: %{"code" => code, "message" => message}
  def new(code, message, data), do: %{"code" => code, "message" => message, "data" => data}

  def parse_error, do: new(-32_700, "Invalid JSON payload")

  def invalid_request(reason),
    do: new(-32_600, "Request payload validation error", %{"reason" => reason})

  def method_not_found(method), do: new(-32_601, "Method not found", %{"method" => method})
  def invalid_params(reason), do: new(-32_602, "Invalid parameters", %{"reason" => reason})
  def internal(reason), do: new(-32_603, "Internal error", %{"reason" => reason})

  def task_not_found(id), do: new(-32_001, "Task not found", %{"id" => id})
  def not_cancelable(id), do: new(-32_002, "Task cannot be canceled", %{"id" => id})
  def push_unsupported, do: new(-32_003, "Push Notification is not supported")

  def unsupported(reason),
    do: new(-32_004, "This operation is not supported", %{"reason" => reason})

  @doc "The caller is not who they say, or said nothing. Sent with a 401."
  def unauthenticated(reason), do: new(-32_000, "unauthenticated", %{"reason" => reason})

  @doc "The plane could not be reached, or could not answer. Sent with a 502."
  def plane_unavailable(reason), do: new(-32_000, "unavailable", %{"reason" => reason})

  def too_many_streams do
    new(-32_000, "too many streams", %{
      "reason" => "this replica holds its limit of open streams; retry shortly"
    })
  end

  @doc """
  What a plane error means to an A2A caller.

  `not_found` and `forbidden` on a task are both "no such task": the plane already
  refuses to say whether a session another principal cannot see exists, and the facade
  should not say more than the plane does.
  """
  @spec from_plane(PlaneError.t(), String.t() | nil) :: t()
  def from_plane(%PlaneError{message: "not_found"}, id) when is_binary(id),
    do: task_not_found(id)

  def from_plane(%PlaneError{message: "forbidden"}, id) when is_binary(id),
    do: task_not_found(id)

  def from_plane(%PlaneError{message: "invalid_params", data: data}, _id),
    do: invalid_params(reason_of(data))

  def from_plane(%PlaneError{message: "unauthenticated"} = error, _id),
    do: unauthenticated(reason_of(error.data))

  def from_plane(%PlaneError{} = error, _id) do
    new(-32_000, error.message, error.data && stringify(error.data))
  end

  defp reason_of(%{reason: reason}), do: to_string(reason)
  defp reason_of(%{"reason" => reason}), do: to_string(reason)
  defp reason_of(other), do: inspect(other)

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: other
end
