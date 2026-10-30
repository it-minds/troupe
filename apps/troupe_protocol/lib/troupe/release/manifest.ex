defmodule Troupe.Release.Manifest do
  @moduledoc """
  A release's `manifest.json` (#66): the version, what the release works with, then
  every file the release publishes with its component, its target, its size and its
  sha256. CI writes it and signs it (`scripts/release-manifest.exs`); a client checks the
  signature (`Troupe.Release.Minisign`), then each file it downloads against it. Nothing
  in it is taken before the signature holds, so what it says it supports is the release
  key's word, as its files are.

      {
        "format": 1,
        "version": "0.34.0-beta",
        "supports": {"plane": ">= 0.30.0-beta", "protocol": "1"},
        "artifacts": [
          {"component": "tui", "target": "linux_x86_64", "file": "troupe-0.13.0-beta-linux_x86_64", "size": 41234567, "sha256": "..."},
          ...
        ]
      }

  `supports` is read from the repository's `COMPATIBILITY` file (`compatibility/1`): the
  plane versions this release's clients work with, as a requirement, and the protocol
  version they speak. It was added within format 1, so a manifest from before it has
  none, and that is read as not knowing (`supports: nil`), never as supporting every
  plane. A requirement is comparisons joined by `and`, each `>=`, `>`, `<=`, `<` or `==`
  and a version, which every client can evaluate the same way SemVer orders versions.

  One artifact to a line, written the same way every time, so that a shell installer
  finds a file's line with `grep` and the bytes signed are the bytes a reader gets.
  `component` is `daemon`, `tui`, `desktop`, `installer`, `chart`, `vscode`, `licence` or
  `other`; `target` is one of `targets/0`, `macos_universal` for the desktop app's one
  macOS build, or `null` for a file that runs anywhere.

  Like `Troupe.Release.Minisign` it needs only `:crypto` and `JSON`, so the script that
  writes it loads it from source.
  """

  @format 1
  @targets ~w(linux_x86_64 linux_aarch64 macos_x86_64 macos_aarch64 windows_x86_64)
  # What a manifest is about, never in it: itself, its signature, and SHA256SUMS, which
  # is written after it.
  @not_artifacts ~w(manifest.json manifest.json.minisig SHA256SUMS)

  @enforce_keys [:version, :artifacts]
  defstruct [:version, :artifacts, supports: nil]

  @type artifact :: %{
          component: String.t(),
          target: String.t() | nil,
          file: String.t(),
          size: non_neg_integer(),
          sha256: String.t()
        }
  @type supports :: %{plane: String.t(), protocol: String.t()}
  @type t :: %__MODULE__{
          version: String.t(),
          artifacts: [artifact()],
          supports: supports() | nil
        }

  @doc "The five targets a release builds the daemon and the TUI for."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc """
  The manifest of the release in `dir`: every regular file in it, by name, bar the
  manifest's own files, and `supports` where it is given.
  """
  @spec build(String.t(), Path.t(), supports() | nil) :: t()
  def build(version, dir, supports \\ nil) do
    artifacts =
      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reject(&(&1 in @not_artifacts))
      |> Enum.filter(&File.regular?(Path.join(dir, &1)))
      |> Enum.map(fn file ->
        path = Path.join(dir, file)
        {component, target} = classify(version, file)

        %{
          component: component,
          target: target,
          file: file,
          size: File.stat!(path).size,
          sha256: sha256(path)
        }
      end)

    %__MODULE__{version: version, artifacts: artifacts, supports: supports}
  end

  @doc """
  What a `COMPATIBILITY` file says, as the manifest's `supports`, or a sentence saying
  which line is wrong.

  One fact to a line, its name and then its value: `plane` and a requirement
  (`plane >= 0.30.0-beta`), `protocol` and a version (`protocol 1`). A line that starts
  with `#`, and an empty one, is not read. Both facts are needed, once each.
  """
  @spec compatibility(String.t()) :: {:ok, supports()} | {:error, String.t()}
  def compatibility(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, n} -> {String.trim(line), n} end)
    |> Enum.reject(fn {line, _n} -> line == "" or String.starts_with?(line, "#") end)
    |> Enum.reduce_while({:ok, %{}}, &fact/2)
    |> case do
      {:ok, %{plane: _, protocol: _} = supports} -> {:ok, supports}
      {:ok, partial} -> {:error, "names no #{if partial[:plane], do: "protocol", else: "plane"}"}
      error -> error
    end
  end

  defp fact({line, n}, {:ok, acc}) do
    {name, value} =
      case String.split(line, ~r/\s+/, parts: 2) do
        [name, value] -> {name, String.trim(value)}
        [name] -> {name, ""}
      end

    key = %{"plane" => :plane, "protocol" => :protocol}[name]

    case wrong(key, name, value, acc) do
      nil -> {:cont, {:ok, Map.put(acc, key, value)}}
      why -> {:halt, {:error, "line #{n}: " <> why}}
    end
  end

  defp wrong(nil, name, _value, _acc), do: "#{inspect(name)} is not plane or protocol"

  defp wrong(key, name, value, acc) do
    cond do
      Map.has_key?(acc, key) ->
        "#{name} is said twice"

      key == :plane and not requirement?(value) ->
        "#{inspect(value)} is not a requirement (comparisons joined by and, " <>
          "each >=, >, <=, < or == and a version)"

      key == :protocol and not Regex.match?(~r/\A[1-9][0-9]*\z/, value) ->
        "#{inspect(value)} is not a protocol version"

      true ->
        nil
    end
  end

  @doc """
  Whether `requirement` is one a manifest may carry: comparisons joined by `and`, each one
  of `>=`, `>`, `<=`, `<` or `==` and a SemVer version.
  """
  @spec requirement?(term()) :: boolean()
  def requirement?(requirement) when is_binary(requirement) do
    requirement
    |> String.split(" and ")
    |> Enum.all?(fn part ->
      case Regex.run(~r/\A\s*(>=|<=|==|>|<)\s*(\S+)\s*\z/, part) do
        [_, _op, version] -> match?({:ok, _}, Version.parse(version))
        nil -> false
      end
    end)
  end

  def requirement?(_requirement), do: false

  @doc """
  Whether a release's `supports` covers a plane at `plane_version`: `true` or `false`, or
  `:unknown` where the manifest says nothing of planes (one from before it did) or the
  plane's version is not one SemVer reads. Versions are ordered as SemVer orders them, a
  pre-release before its release, as the rest of `troupe update` orders them.
  """
  @spec supports?(t(), String.t() | nil) :: boolean() | :unknown
  def supports?(%__MODULE__{supports: %{plane: requirement}}, plane_version)
      when is_binary(plane_version) do
    with {:ok, version} <- Version.parse(plane_version),
         {:ok, requirement} <- Version.parse_requirement(requirement) do
      Version.match?(version, requirement, allow_pre: true)
    else
      _unreadable -> :unknown
    end
  end

  def supports?(_manifest, _plane_version), do: :unknown

  @doc """
  What a release's file is, from its name: `{component, target}`. The names are the ones
  `native.yml` and `release.yml` give; the desktop app's carry its version without the
  pre-release part (`scripts/version.exs`).
  """
  @spec classify(String.t(), String.t()) :: {String.t(), String.t() | nil}
  def classify(version, file) do
    cond do
      target = suffix(file, "troupe-daemon-#{version}-", ".tar.gz") ->
        {"daemon", target}

      target =
          suffix(file, "troupe-#{version}-", ".exe") || suffix(file, "troupe-#{version}-", "") ->
        {"tui", target}

      file == "troupe-#{version}.tgz" ->
        {"chart", nil}

      true ->
        named(version, file)
    end
  end

  # `latest.json` is what the desktop app's updater reads (Decision 874); the `.sig` beside
  # each of its update files is named like the file, and so is the desktop app's too.
  @named %{
    "install.sh" => "installer",
    "install.ps1" => "installer",
    "latest.json" => "desktop",
    "troupe.vsix" => "vscode",
    "LICENSE" => "licence",
    "NOTICE" => "licence",
    "THIRD-PARTY-NOTICES.txt" => "licence"
  }

  defp named(version, file) do
    desktop = version |> String.split("-") |> hd()

    cond do
      component = @named[file] ->
        {component, nil}

      String.starts_with?(file, ["Troupe_#{desktop}_", "Troupe-#{desktop}-"]) ->
        {"desktop", desktop_target(file)}

      true ->
        {"other", nil}
    end
  end

  defp suffix(file, prefix, ext) do
    with true <- String.starts_with?(file, prefix) and String.ends_with?(file, ext),
         target = file |> String.replace_prefix(prefix, "") |> String.replace_suffix(ext, ""),
         true <- target in @targets do
      target
    else
      _ -> nil
    end
  end

  defp desktop_target(file) do
    cond do
      String.contains?(file, "universal") -> "macos_universal"
      String.contains?(file, "x64") -> "windows_x86_64"
      String.contains?(file, "amd64") or String.contains?(file, "x86_64") -> "linux_x86_64"
      true -> nil
    end
  end

  @doc """
  The manifest as it is signed: the same bytes for the same release, one artifact to a
  line. Without `supports`, the bytes are the ones a manifest had before it was added.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{version: version, artifacts: artifacts} = manifest) do
    lines =
      Enum.map_join(artifacts, ",\n", fn a ->
        "    {" <>
          Enum.map_join(
            [
              component: a.component,
              target: a.target,
              file: a.file,
              size: a.size,
              sha256: a.sha256
            ],
            ", ",
            fn {key, value} -> ~s("#{key}": ) <> JSON.encode!(value) end
          ) <> "}"
      end)

    """
    {
      "format": #{@format},
      "version": #{JSON.encode!(version)},
    #{supports_line(manifest.supports)}  "artifacts": [
    #{lines}
      ]
    }
    """
  end

  defp supports_line(nil), do: ""

  defp supports_line(%{plane: plane, protocol: protocol}),
    do:
      ~s(  "supports": {"plane": #{JSON.encode!(plane)}, "protocol": #{JSON.encode!(protocol)}},\n)

  @doc "A manifest from its bytes, checked for the shape a client relies on."
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, %{"format" => @format, "version" => version, "artifacts" => artifacts} = json}
         when is_binary(version) and is_list(artifacts) <- JSON.decode(bytes),
         {:ok, artifacts} <- artifacts(artifacts, []),
         {:ok, supports} <- supports(json["supports"]) do
      {:ok, %__MODULE__{version: version, artifacts: artifacts, supports: supports}}
    else
      {:ok, %{"format" => format}} when format != @format ->
        {:error,
         "is in format #{inspect(format)}, which this build does not read (it reads #{@format}); a newer troupe does"}

      {:error, why} when is_binary(why) ->
        {:error, why}

      _other ->
        {:error, "is not a release manifest"}
    end
  end

  defp supports(nil), do: {:ok, nil}

  defp supports(%{"plane" => plane, "protocol" => protocol})
       when is_binary(plane) and is_binary(protocol) do
    if requirement?(plane),
      do: {:ok, %{plane: plane, protocol: protocol}},
      else: {:error, "says it supports planes #{inspect(plane)}, which is not a requirement"}
  end

  defp supports(_other), do: {:error, "has a supports without its plane and protocol"}

  defp artifacts([], acc), do: {:ok, Enum.reverse(acc)}

  defp artifacts([entry | rest], acc) do
    case artifact(entry) do
      {:ok, artifact} -> artifacts(rest, [artifact | acc])
      error -> error
    end
  end

  defp artifact(%{"component" => c, "target" => t, "file" => f, "size" => s, "sha256" => h}) do
    typed? =
      Enum.all?([
        is_binary(c),
        is_binary(t) or is_nil(t),
        is_binary(f),
        is_integer(s),
        is_binary(h)
      ])

    cond do
      not typed? or s < 0 ->
        {:error, "has an artifact whose fields are not what they should be"}

      plain_name?(f) and sha256?(h) ->
        {:ok, %{component: c, target: t, file: f, size: s, sha256: h}}

      true ->
        {:error, "names a file #{inspect(f)} it cannot be about"}
    end
  end

  defp artifact(_other),
    do: {:error, "has an artifact without its component, target, file, size and sha256"}

  # A file name is where a client puts what it downloads: never a path.
  defp plain_name?(file),
    do:
      Path.basename(file) == file and file not in ["", ".", ".."] and
        not String.contains?(file, "\\")

  defp sha256?(hex), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, hex)

  @doc "The artifact of `component` built for `target`, or `nil`."
  @spec find(t(), String.t(), String.t()) :: artifact() | nil
  def find(%__MODULE__{artifacts: artifacts}, component, target),
    do: Enum.find(artifacts, &(&1.component == component and &1.target == target))

  @doc """
  Whether the file at `path` is the artifact: its size first, then its sha256. A refusal
  is a sentence naming the file.
  """
  @spec check_file(artifact(), Path.t()) :: :ok | {:error, String.t()}
  def check_file(%{file: file, size: size, sha256: expected}, path) do
    case File.stat(path) do
      {:ok, %{size: ^size}} ->
        actual = sha256(path)

        if actual == expected,
          do: :ok,
          else:
            {:error,
             "#{file} is not the file the signed manifest names (sha256 #{actual}, not #{expected})"}

      {:ok, %{size: other}} ->
        {:error, "#{file} is #{other} bytes, and the signed manifest says #{size}"}

      {:error, reason} ->
        {:error, "#{file} could not be read: #{:file.format_error(reason)}"}
    end
  end

  @doc "A file's sha256, lower-case hexadecimal, read a megabyte at a time."
  @spec sha256(Path.t()) :: String.t()
  def sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  This machine's target, as the release names its builds, or `nil` on one it does not
  build for.
  """
  @spec target() :: String.t() | nil
  def target, do: target(:os.type(), to_string(:erlang.system_info(:system_architecture)))

  @doc false
  @spec target({atom(), atom()}, String.t()) :: String.t() | nil
  def target(os_type, architecture) do
    target = "#{os(os_type)}_#{arch(architecture)}"
    if target in @targets, do: target
  end

  defp os({:win32, _}), do: "windows"
  defp os({:unix, :darwin}), do: "macos"
  defp os({:unix, :linux}), do: "linux"
  defp os(_other), do: nil

  defp arch(architecture) do
    cond do
      String.starts_with?(architecture, ["x86_64", "amd64"]) -> "x86_64"
      String.starts_with?(architecture, ["aarch64", "arm64"]) -> "aarch64"
      # An older Windows BEAM said `win32` whatever the processor; a release builds x86_64.
      architecture == "win32" -> "x86_64"
      true -> nil
    end
  end
end
