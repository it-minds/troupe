# The desktop app's update (#66, Decision 874): a `.sig` beside each file the desktop app
# updates itself from, and `latest.json`, the document Tauri's updater reads, signed with
# the release key: the key that signs the manifest, so one key covers everything a client
# installs.
#
#   RELEASE_MINISIGN_KEY=... elixir scripts/release-desktop-update.exs VERSION DIR --base URL [--keys FILE]
#
# The files are the ones each installer puts on a machine: the per-user setup on Windows
# (`Troupe_<v>_x64-setup.exe`), the app archive on macOS (`Troupe_<v>_universal.app.tar.gz`,
# which `native.yml` packs beside the disk image) and the AppImage on Linux
# (`Troupe_<v>_amd64.AppImage`), `<v>` the version without its pre-release part, as the
# desktop app's builds are numbered. `--base` is where the release's files are downloaded
# from, for the URLs in `latest.json`; the desktop app itself downloads from wherever it
# found the release's signed manifest.
#
# A `.sig` is what Tauri writes: one minisign signature, base64-encoded, whose trusted
# comment names the file and the version, which the updater holds the version it is
# offered to. It is made with RELEASE_MINISIGN_KEY, or during a key rotation with
# RELEASE_MINISIGN_KEY_PREVIOUS: the apps that update to a rotation release were built
# before it and trust the old key alone, and an app built from it trusts both (Decision
# 865's rotation). Run before `release-manifest.exs`, so the manifest names the `.sig`
# files and `latest.json` with everything else.
#
# Nothing is written unless the key checks out as the manifest's does and every signature
# checks with the clients' own verifier against the list. `--keys` names another list, for
# the test that runs this with a throwaway key.
root = Path.expand("..", __DIR__)
Code.require_file(Path.join(root, "apps/troupe_core/lib/troupe/release/minisign.ex"))

alias Troupe.Release.Minisign

defmodule DesktopUpdate do
  @moduledoc false

  def fail(message) do
    IO.puts(:stderr, "release-desktop-update: " <> message)
    System.halt(1)
  end

  def secret(name) do
    case System.get_env(name, "") |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  # Each update file, and the targets Tauri's updater looks it up by: `<os>-<arch>`, and
  # `<os>-<arch>-<installer>`, which it tries first.
  def files(desktop) do
    [
      {"Troupe_#{desktop}_x64-setup.exe", ~w(windows-x86_64 windows-x86_64-nsis)},
      {"Troupe_#{desktop}_universal.app.tar.gz",
       ~w(darwin-aarch64 darwin-x86_64 darwin-aarch64-app darwin-x86_64-app)},
      {"Troupe_#{desktop}_amd64.AppImage", ~w(linux-x86_64 linux-x86_64-appimage)}
    ]
  end
end

{opts, args, invalid} =
  OptionParser.parse(System.argv(), strict: [keys: :string, base: :string])

{version, dir} =
  case {args, invalid, opts[:base]} do
    {[version, dir], [], base} when is_binary(base) ->
      {version, dir}

    _ ->
      DesktopUpdate.fail(
        "usage: elixir scripts/release-desktop-update.exs VERSION DIR --base URL [--keys FILE]"
      )
  end

unless Regex.match?(~r/\A[0-9A-Za-z.+-]+\z/, version),
  do: DesktopUpdate.fail("#{version} is not a version")

unless File.dir?(dir), do: DesktopUpdate.fail("#{dir} is not a directory")

keys_path = opts[:keys] || Path.join(root, "apps/troupe_core/priv/release-keys.txt")

keys =
  case Minisign.parse_key_list(File.read!(keys_path)) do
    {:ok, []} ->
      DesktopUpdate.fail(
        "#{keys_path} holds no release key; the desktop app's update is never published unsigned"
      )

    {:ok, keys} ->
      keys

    {:error, why} ->
      DesktopUpdate.fail("#{keys_path}: #{why}")
  end

parse = fn name ->
  case DesktopUpdate.secret(name) do
    nil ->
      nil

    text ->
      case Minisign.parse_secret_key(text) do
        {:ok, secret} -> secret
        {:error, why} -> DesktopUpdate.fail("#{name} #{why}")
      end
  end
end

primary =
  parse.("RELEASE_MINISIGN_KEY") ||
    DesktopUpdate.fail(
      "RELEASE_MINISIGN_KEY is not set: the release environment's secret holds the release key, " <>
        "and the desktop app's update is never published unsigned"
    )

unless Minisign.public_key(primary) == hd(keys),
  do:
    DesktopUpdate.fail(
      "RELEASE_MINISIGN_KEY is key #{Minisign.key_id(primary)}, which is not the first in #{keys_path}"
    )

previous = parse.("RELEASE_MINISIGN_KEY_PREVIOUS")

if previous && Minisign.public_key(previous) not in tl(keys),
  do:
    DesktopUpdate.fail(
      "RELEASE_MINISIGN_KEY_PREVIOUS is not one of the other keys in #{keys_path}"
    )

signer = previous || primary
desktop = version |> String.split("-") |> hd()
base = String.trim_trailing(opts[:base], "/")

found =
  for {file, targets} <- DesktopUpdate.files(desktop),
      File.regular?(Path.join(dir, file)),
      do: {file, targets}

if found == [] do
  DesktopUpdate.fail(
    "#{dir} holds none of the desktop app's update files (#{Enum.map_join(DesktopUpdate.files(desktop), ", ", &elem(&1, 0))})"
  )
end

signed =
  for {file, targets} <- found do
    bytes = File.read!(Path.join(dir, file))
    trusted = "timestamp:#{System.os_time(:second)}\tfile:#{file}\tversion:#{version}"
    text = Minisign.sign(bytes, signer, trusted_comment: trusted)

    # The clients' own check, against the list they are built with, before anything is written.
    case Minisign.verify(bytes, text, keys) do
      {:ok, _} -> :ok
      {:error, why} -> DesktopUpdate.fail("#{file}'s signature #{why}")
    end

    {file, targets, Base.encode64(text)}
  end

platforms =
  for {file, targets, signature} <- signed, target <- targets, into: %{} do
    {target, %{"signature" => signature, "url" => "#{base}/#{URI.encode(file)}"}}
  end

pub_date = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

latest =
  JSON.encode!(%{
    "version" => version,
    "notes" => "Troupe #{version}",
    "pub_date" => pub_date,
    "platforms" => platforms
  })

for {file, _targets, signature} <- signed do
  File.write!(Path.join(dir, file <> ".sig"), signature)
end

File.write!(Path.join(dir, "latest.json"), latest <> "\n")

IO.puts(
  "latest.json: the desktop app #{version} for #{Enum.map_join(signed, ", ", &elem(&1, 0))}, " <>
    "signed by key #{Minisign.key_id(signer)}"
)
