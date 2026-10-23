defmodule Troupe.Plane.Releases do
  @moduledoc """
  Releases kept in the plane's object store, so an organisation's machines update from the
  plane with no way to GitHub (#657).

  `/downloads/v<version>/<file>` hands out what is under `releases/v<version>/` in the
  store; this is how it gets there. `mirror/2` fetches a release's `manifest.json` and its
  signature from where releases are published (GitHub's, unless the deployment names
  another source), checks the signature against the release keys this plane was built
  with, the same keys every client is built with, and only then copies each file the
  manifest names, each held to the manifest's size and sha256, and the manifest and its
  signature last. A manifest the release keys did not sign, or one naming another version,
  is refused with a sentence and nothing is copied.

  The plane checking the release changes nothing about who checks it: every client checks
  the manifest's signature and each file again before it installs anything. What the
  plane adds is that an administrator who mirrors a release that is not the release key's
  is told so at once, rather than by every machine that tries it.

  A release is **mirrored** once its manifest is in the store, which is the last thing
  written: a copy that stopped half way names no manifest, and `list/1` does not count it.
  The files are copied in the background (`start/2`), since a release is a few hundred
  megabytes, and a copy under way on this replica is listed as `mirroring`.
  """

  alias Troupe.ObjectStore
  alias Troupe.Protocol.ClientUpdate
  alias Troupe.Release.{Manifest, Minisign}

  @source "https://github.com/it-minds/troupe/releases/download"
  @prefix "releases/"

  # The release keys every client is built with, read when the plane is compiled, as the
  # clients read them: no setting adds one.
  @keys_path Path.expand("../../../../troupe_core/priv/release-keys.txt", __DIR__)
  @external_resource @keys_path
  @keys (case Minisign.parse_key_list(File.read!(@keys_path)) do
           {:ok, keys} -> keys
           {:error, why} -> raise "apps/troupe_core/priv/release-keys.txt: #{why}"
         end)

  # A manifest and its signature are a few kilobytes; anything much larger is not one.
  @small 1_048_576

  @stand_ins Application.compile_env(:troupe_plane, :release_stand_ins, false)

  @tasks Troupe.Plane.Releases.Tasks
  @registry Troupe.Plane.Releases.Copies


  @doc """
  Where releases are fetched from, each under `v<version>/`: GitHub's release downloads,
  or the deployment's `:releases` `source`.
  """
  @spec source() :: String.t()
  def source do
    case Application.get_env(:troupe_plane, :releases, [])[:source] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _none -> @source
    end
  end

  @typedoc "A release whose manifest checked: the manifest, and the bytes of it and its signature."
  @type checked :: %{manifest: Manifest.t(), text: binary(), signature: binary()}

  @doc """
  Check a release's manifest at its source: the manifest once its signature holds against
  the release keys and it names `version`, with the bytes that were checked, or a sentence
  saying why not.

  `:keys` stands in for the release keys and `:req` adds to each request's options (a test's
  `plug:`); `:source` for `source/0`.
  """
  @spec check(String.t(), keyword()) :: {:ok, checked()} | {:error, String.t()}
  def check(version, opts \\ []) do
    opts = Keyword.merge(test_opts(), opts)
    base = base(version, opts)

    with :ok <- version_ok(version),
         {:ok, bytes} <- fetch(base, "manifest.json", @small, opts),
         {:ok, signature} <- fetch(base, "manifest.json.minisig", @small, opts),
         :ok <- signed(bytes, signature, base, Keyword.get(opts, :keys, @keys)),
         {:ok, manifest} <- decoded(bytes, base),
         :ok <- same_version(manifest, version, base) do
      {:ok, %{manifest: manifest, text: bytes, signature: signature}}
    end
  end

  @doc """
  Mirror a release whose manifest `check/2` passed: every file it names, each checked
  against it, then the signature and the manifest, the bytes that were checked. `{:ok,
  %{files, bytes}}`, or why it stopped; what was copied before stays, and names no manifest.
  """
  @spec copy(checked(), keyword()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, String.t()}
  def copy(%{manifest: %Manifest{version: version} = manifest} = checked, opts \\ []) do
    opts = Keyword.merge(test_opts(), opts)
    base = base(version, opts)
    store = Keyword.get_lazy(opts, :store, &ObjectStore.from_env/0)

    copied =
      Enum.reduce_while(manifest.artifacts, {:ok, 0}, fn artifact, {:ok, bytes} ->
        case copy_artifact(artifact, base, store, version, opts) do
          {:ok, size} -> {:cont, {:ok, bytes + size}}
          {:error, _why} = error -> {:halt, error}
        end
      end)

    with {:ok, bytes} <- copied,
         :ok <- put(store, key(version, "manifest.json.minisig"), checked.signature),
         :ok <- put(store, key(version, "manifest.json"), checked.text) do
      {:ok, %{files: length(manifest.artifacts), bytes: bytes}}
    end
  end

  @doc """
  Check a release and copy it in the background: `{:ok, manifest}` once the check passes
  and the copy is under way, or why not. `then` is called with the copy's outcome. A copy
  of the same version already under way on this replica is not started twice.
  """
  @spec start(String.t(), keyword()) :: {:ok, Manifest.t()} | {:error, String.t()}
  def start(version, opts \\ []) do
    then = Keyword.get(opts, :then, fn _outcome -> :ok end)

    with {:ok, checked} <- check(version, opts),
         :ok <- not_under_way(version) do
      parent = self()
      ref = make_ref()

      {:ok, _pid} =
        Task.Supervisor.start_child(@tasks, fn ->
          registered = Registry.register(@registry, version, DateTime.utc_now())
          send(parent, {ref, registered})
          if match?({:ok, _owner}, registered), do: then.(copy(checked, opts))
        end)

      receive do
        {^ref, {:ok, _owner}} -> {:ok, checked.manifest}
        {^ref, {:error, {:already_registered, _pid}}} -> not_under_way(version)
      end
    end
  end

  defp not_under_way(version) do
    case Registry.lookup(@registry, version) do
      [] -> :ok
      [_copy] -> {:error, "release #{version} is being mirrored already"}
    end
  end

  @doc """
  The releases in the store: each version whose manifest is there, newest first, with how
  many files it names, and those a copy is under way for on this replica.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def list(opts \\ []) do
    store = Keyword.get_lazy(opts, :store, &ObjectStore.from_env/0)

    case ObjectStore.list(store, @prefix) do
      {:ok, keys} ->
        mirrored =
          for "releases/v" <> rest <- keys,
              [version, "manifest.json"] <- [String.split(rest, "/", parts: 2)],
              ClientUpdate.version?(version),
              do: %{"version" => version, "state" => "mirrored", "files" => files(keys, version)}

        under_way =
          for version <- copying(),
              not Enum.any?(mirrored, &(&1["version"] == version)),
              do: %{"version" => version, "state" => "mirroring", "files" => files(keys, version)}

        {:ok, Enum.sort(mirrored ++ under_way, &newer?/2)}

      {:error, reason} ->
        {:error, "the object store did not list the releases in it: #{inspect(reason)}"}
    end
  end

  defp copying do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  defp files(keys, version) do
    prefix = "releases/v#{version}/"
    Enum.count(keys, &(String.starts_with?(&1, prefix) and not String.ends_with?(&1, "/")))
  end

  defp newer?(%{"version" => a}, %{"version" => b}), do: not ClientUpdate.older?(a, b)

  # -- one file -----------------------------------------------------------------------

  defp copy_artifact(%{file: file, size: size, sha256: sha256}, base, store, version, opts) do
    with {:ok, bytes} <- fetch(base, file, size, opts),
         :ok <- held_to(bytes, file, size, sha256),
         :ok <- put(store, key(version, file), bytes) do
      {:ok, size}
    end
  end

  defp held_to(bytes, file, size, sha256) do
    cond do
      byte_size(bytes) != size ->
        {:error,
         "#{file} is #{byte_size(bytes)} bytes, and the signed manifest says #{size}: " <>
           "the copy stopped there, and the release is not mirrored"}

      Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) != sha256 ->
        {:error,
         "#{file} is not the file the signed manifest names (its sha256 differs): " <>
           "the copy stopped there, and the release is not mirrored"}

      true ->
        :ok
    end
  end

  defp put(store, key, bytes) do
    case ObjectStore.put(store, key, bytes) do
      {:ok, _put} -> :ok
      {:error, reason} -> {:error, "the object store refused #{key}: #{inspect(reason)}"}
    end
  end

  defp key(version, file), do: "#{@prefix}v#{version}/#{file}"

  # -- the source ---------------------------------------------------------------------

  # A test run's stand-ins for the release keys and the network (`:releases`' `keys:` and
  # `req:`), read only where the build was compiled for tests: in a release no setting adds
  # a key.
  defp test_opts do
    if @stand_ins,
      do: :troupe_plane |> Application.get_env(:releases, []) |> Keyword.take([:keys, :req]),
      else: []
  end

  defp base(version, opts),
    do: "#{opts |> Keyword.get_lazy(:source, &source/0) |> String.trim_trailing("/")}/v#{version}"

  defp fetch(base, file, limit, opts) do
    url = "#{base}/#{file}"
    options = [retry: false, receive_timeout: 600_000, decode_body: false, redirect: true]

    case Req.get(url, Keyword.merge(options, Keyword.get(opts, :req, []))) do
      {:ok, %{status: 200, body: body}} when byte_size(body) <= limit ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, "#{url} is larger than it can be: nothing more is mirrored"}

      {:ok, %{status: 404}} ->
        {:error, missing(file, base)}

      {:ok, %{status: status}} ->
        {:error, "#{url} answered #{status}: nothing more is mirrored"}

      {:error, exception} ->
        {:error, "could not reach #{url}: #{Exception.message(exception)}"}
    end
  end

  defp missing("manifest.json", base),
    do:
      "the release at #{base} has no manifest.json: releases from before 0.13 and pre-releases " <>
        "are not signed, and the plane mirrors only a signed release; nothing is mirrored"

  defp missing(file, base),
    do: "the release at #{base} has no #{file}: nothing more is mirrored"

  defp version_ok(version) do
    if ClientUpdate.version?(version),
      do: :ok,
      else: {:error, "#{inspect(version)} is not a version a release is numbered by"}
  end

  defp signed(bytes, signature, base, keys) do
    case Minisign.verify(bytes, signature, keys) do
      {:ok, _signed} ->
        :ok

      {:error, why} ->
        {:error,
         "the manifest of the release at #{base} #{why}: it is not the release key's, and " <>
           "nothing is mirrored"}
    end
  end

  defp decoded(bytes, base) do
    case Manifest.decode(bytes) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, why} -> {:error, "the signed manifest at #{base} #{why}; nothing is mirrored"}
    end
  end

  # An older signed manifest served under a newer number is still signed: what it names has
  # to be what was asked for.
  defp same_version(%Manifest{version: version}, version, _base), do: :ok

  defp same_version(%Manifest{version: other}, version, base),
    do: {:error, "the release at #{base} is #{other}, not #{version}; nothing is mirrored"}
end
