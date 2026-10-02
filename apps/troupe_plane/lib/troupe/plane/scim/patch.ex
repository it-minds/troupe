defmodule Troupe.Plane.SCIM.Patch do
  @moduledoc """
  A SCIM `PatchOp` (RFC 7644 §3.5.2), read into operations the plane can apply.

  Read the way Microsoft Entra ID writes one as well as the way the RFC does, because it
  is the client that sends them: `op` in any case (`Replace`), and a `value` object with
  no `path` whose keys are attributes or, with Entra, paths themselves (`name.givenName`,
  `emails[type eq "work"].value`), each of which is one operation. Nothing here knows
  which attributes the plane keeps; `Troupe.Plane.SCIM` decides that.

  A path comes out split, `{attribute, value_filter, sub_attribute}`, with the names in
  lower case, since SCIM's are case-insensitive, and the resource's own schema URN taken
  off the front. An extension's attribute keeps its URN, and is one the plane does not
  keep.
  """

  @ops %{"add" => :add, "replace" => :replace, "remove" => :remove}

  @path ~r/\A([A-Za-z][A-Za-z0-9_$-]*)(?:\[(.*)\])?(?:\.([A-Za-z][A-Za-z0-9_$-]*))?\z/u

  @type op :: :add | :replace | :remove
  @type path :: {String.t(), String.t() | nil, String.t() | nil}
  @type operation :: {op(), path(), term()}
  @type error :: {String.t(), String.t()}

  @doc "The operations in a `PatchOp` body, in order, for a resource of this schema."
  @spec operations(term(), String.t()) :: {:ok, [operation()]} | {:error, error()}
  def operations(body, schema) when is_map(body) do
    case field(body, "Operations") do
      [_ | _] = operations -> collect(operations, schema)
      _ -> {:error, {"invalidSyntax", "a PATCH body is a PatchOp with a list of Operations"}}
    end
  end

  def operations(_body, schema), do: operations(%{}, schema)

  defp collect(operations, schema) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, read} ->
      case read(operation, schema) do
        {:ok, more} -> {:cont, {:ok, read ++ more}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read(operation, schema) when is_map(operation) do
    with {:ok, op} <- op(field(operation, "op")) do
      case field(operation, "path") do
        nil ->
          spread(op, field(operation, "value"), schema)

        path ->
          with {:ok, path} <- path(path, schema),
               do: {:ok, [{op, path, field(operation, "value")}]}
      end
    end
  end

  defp read(_operation, _schema), do: {:error, {"invalidSyntax", "an operation is an object"}}

  defp op(name) when is_binary(name) do
    case Map.fetch(@ops, String.downcase(name)) do
      {:ok, op} -> {:ok, op}
      :error -> {:error, {"invalidSyntax", "op is add, replace or remove, not #{inspect(name)}"}}
    end
  end

  defp op(name),
    do: {:error, {"invalidSyntax", "op is add, replace or remove, not #{inspect(name)}"}}

  # No path. `remove` then has nothing to aim at (§3.5.2.2); `add` and `replace` carry an
  # object whose every key is set as if it were the path.
  defp spread(:remove, _value, _schema), do: {:error, {"noTarget", "remove needs a path"}}

  defp spread(op, value, schema) when is_map(value) do
    Enum.reduce_while(value, {:ok, []}, fn {key, value}, {:ok, read} ->
      case path(key, schema) do
        {:ok, path} -> {:cont, {:ok, read ++ [{op, path, value}]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp spread(_op, _value, _schema),
    do: {:error, {"invalidValue", "add or replace without a path takes an object"}}

  defp path(path, schema) when is_binary(path) do
    own = Regex.compile!("\\A" <> Regex.escape(schema <> ":"), "i")

    cond do
      Regex.match?(own, path) ->
        split(Regex.replace(own, path, ""), path)

      String.starts_with?(String.downcase(path), "urn:") ->
        {:ok, {String.downcase(path), nil, nil}}

      true ->
        split(path, path)
    end
  end

  defp path(path, _schema),
    do: {:error, {"invalidPath", "a path is a string, not #{inspect(path)}"}}

  defp split(rest, path) do
    case Regex.run(@path, rest) do
      [_, attribute] ->
        {:ok, {String.downcase(attribute), nil, nil}}

      [_, attribute, filter] ->
        {:ok, {String.downcase(attribute), blank(filter), nil}}

      [_, attribute, filter, sub] ->
        {:ok, {String.downcase(attribute), blank(filter), String.downcase(sub)}}

      nil ->
        {:error, {"invalidPath", "cannot read the path #{inspect(path)}"}}
    end
  end

  defp blank(""), do: nil
  defp blank(filter), do: filter

  # SCIM's names are case-insensitive, the message's own included.
  defp field(map, name) do
    case Map.fetch(map, name) do
      {:ok, value} ->
        value

      :error ->
        wanted = String.downcase(name)

        map
        |> Enum.find_value({nil}, fn {key, value} ->
          if is_binary(key) and String.downcase(key) == wanted, do: {value}
        end)
        |> elem(0)
    end
  end
end
