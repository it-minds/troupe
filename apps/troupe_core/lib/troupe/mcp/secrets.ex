defmodule Troupe.MCP.Secrets do
  @moduledoc """
  A value one of a person's own MCP servers needs, kept in the operating system's
  credential store rather than in `mcp.json`.

  An entry's variable or header is written `{secret:<server>/<key>}`, and the value is
  read from the store (`Troupe.Keyring`, under `mcp/<server>/<key>`) when the server
  starts, as `{env:VAR}` is read from the environment. The file holds the reference and
  nothing else, so a file people link, copy and commit carries no key; the value never
  comes back from the daemon, and a client shows the key as set or missing.

  A value is kept base64-encoded, since each platform's store takes it through a shell or
  a console and a key may be any bytes a person pastes.

  A store this machine does not have (a Linux box with no Secret Service) answers
  `{:error, :unavailable}`: writing says so, and a server that needs a value from it is
  refused with that reason rather than started without it.
  """

  @reference ~r/\{secret:([A-Za-z0-9][A-Za-z0-9_.\/-]*)\}/

  @typedoc "What a server's string needs from the store: nothing, or a reference it lacks."
  @type lack :: {:missing, String.t()} | {:unavailable, String.t(), term()}

  @doc """
  The name a server's key is kept under, without the braces: `<server>/<key>` for one of
  the person's own file, and under the workspace's prefix for one of a workspace's, so a
  workspace's file reads only what was set for it (`Troupe.MCP.Local`).
  """
  @spec ref(String.t(), String.t(), Path.t() | nil) :: String.t()
  def ref(server, key, workspace \\ nil)
  def ref(server, key, nil), do: "#{server}/#{key}"
  def ref(server, key, workspace), do: workspace_prefix(workspace) <> "#{server}/#{key}"

  @doc "The reference a server's key is written as: `{secret:<ref>}`."
  @spec reference(String.t()) :: String.t()
  def reference(ref), do: "{secret:#{ref}}"

  @doc "Where a workspace's secrets are kept: `ws-<16 hex of its real path>/`."
  @spec workspace_prefix(Path.t()) :: String.t()
  def workspace_prefix(workspace) do
    real =
      case Troupe.Workspace.real_path(workspace) do
        {:ok, real} -> real
        {:error, _why} -> Path.expand(workspace)
      end

    "ws-" <>
      (:sha256 |> :crypto.hash(real) |> Base.encode16(case: :lower) |> binary_part(0, 16)) <> "/"
  end

  @doc "Whether a string names a value in the store."
  @spec reference?(term()) :: boolean()
  def reference?(value) when is_binary(value), do: Regex.match?(@reference, value)
  def reference?(_value), do: false

  @doc "The references a string names, in order."
  @spec refs(term()) :: [String.t()]
  def refs(value) when is_binary(value),
    do: @reference |> Regex.scan(value) |> Enum.map(fn [_, ref] -> ref end)

  def refs(_value), do: []

  @typedoc "What the store answered for each reference, looked up once."
  @type found :: %{String.t() => {:ok, String.t()} | :none | {:error, term()}}

  @doc """
  Look up every reference `values` name, once each: each lookup asks the platform's
  store, which is a process of its own, so a server's strings share one answer.
  """
  @spec lookup([term()]) :: found()
  def lookup(values) do
    values |> Enum.flat_map(&refs/1) |> Enum.uniq() |> Map.new(&{&1, get(&1)})
  end

  @doc "The first reference among `values` the store could not answer, or `nil`."
  @spec lacking([term()], found()) :: lack() | nil
  def lacking(values, found) do
    values
    |> Enum.flat_map(&refs/1)
    |> Enum.find_value(fn ref ->
      case Map.get(found, ref, :none) do
        {:ok, _value} -> nil
        {:error, why} -> {:unavailable, ref, why}
        :none -> {:missing, ref}
      end
    end)
  end

  @doc "A string with each reference replaced by its value, as `found` has it."
  @spec fill(term(), found()) :: term()
  def fill(value, found) when is_binary(value) do
    Regex.replace(@reference, value, fn _match, ref ->
      case Map.get(found, ref) do
        {:ok, secret} -> secret
        _none -> ""
      end
    end)
  end

  def fill(value, _found), do: value

  @doc "Keep a value under `ref`, replacing one there."
  @spec put(String.t(), String.t()) :: :ok | {:error, term()}
  def put(ref, value) when is_binary(value),
    do: Troupe.Keyring.put(entry(ref), Base.encode64(value))

  @doc "Forget the value under `ref`; `:ok` where there was none."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(ref), do: Troupe.Keyring.delete(entry(ref))

  @doc "The value under `ref`, `:none`, or why the store could not say."
  @spec get(String.t()) :: {:ok, String.t()} | :none | {:error, term()}
  def get(ref) do
    case Troupe.Keyring.get(entry(ref)) do
      {:ok, encoded} ->
        case Base.decode64(encoded) do
          {:ok, value} -> {:ok, value}
          :error -> {:ok, encoded}
        end

      other ->
        other
    end
  end

  defp entry(ref), do: "mcp/" <> ref
end
