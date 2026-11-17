defmodule Troupe.ObjectStore.Head do
  @moduledoc """
  What a `HEAD` of an object answers, read the same way whether the request was signed
  with the store's credential (`Troupe.ObjectStore`) or carried a presigned URL
  (`Troupe.ObjectStore.Signed`).
  """

  @doc """
  The object's size and its `x-amz-meta-` metadata from the response, `:not_found` for a
  404, and the status and body of anything else.
  """
  @spec answer(String.t(), {:ok, Req.Response.t()} | {:error, term()}) ::
          {:ok, map()} | {:error, :not_found | term()}
  def answer(key, {:ok, %{status: status} = response}) when status in 200..299,
    do: {:ok, %{key: key, bytes: content_length(response), metadata: metadata(response)}}

  def answer(_key, {:ok, %{status: 404}}), do: {:error, :not_found}
  def answer(_key, {:ok, response}), do: {:error, {:unexpected_status, response.status, response.body}}
  def answer(_key, {:error, reason}), do: {:error, reason}

  defp content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [value | _] -> String.to_integer(value)
      _ -> 0
    end
  end

  defp metadata(response) do
    response.headers
    |> Enum.flat_map(fn
      {"x-amz-meta-" <> name, [value | _]} -> [{name, value}]
      {"x-amz-meta-" <> name, value} when is_binary(value) -> [{name, value}]
      _ -> []
    end)
    |> Map.new()
  end
end
