# A release's signed manifest (#66, Decision 865): `manifest.json` over every file in DIR,
# and `manifest.json.minisig`, signed with the release key the `release` environment holds.
#
#   RELEASE_MINISIGN_KEY=... elixir scripts/release-manifest.exs VERSION DIR [--keys FILE]
#
# RELEASE_MINISIGN_KEY is the release key as `minisign -G -W` writes it (unencrypted; the
# secret's own protection is the environment's), and its public half must be the first key
# in apps/troupe_core/priv/release-keys.txt, the list every client is built with. During a
# key rotation RELEASE_MINISIGN_KEY_PREVIOUS is the key being retired: it signs too, in a
# second block after the first, so a client built before the rotation can check this
# release, and it must be in the list as well.
#
# Nothing is written unless all of that holds and the signature checks with the clients'
# own verifier against the list: without the key the release is not signed, and the
# workflow stops before it publishes. `--keys` names another list, for the test that runs
# this with a throwaway key.
#
# It loads the two modules it needs from source, so it runs with Elixir alone, without
# the umbrella compiled.
root = Path.expand("..", __DIR__)

for file <- ~w(minisign.ex manifest.ex) do
  Code.require_file(Path.join(root, "apps/troupe_core/lib/troupe/release/#{file}"))
end

alias Troupe.Release.{Manifest, Minisign}

defmodule ReleaseManifest do
  @moduledoc false

  def fail(message) do
    IO.puts(:stderr, "release-manifest: " <> message)
    System.halt(1)
  end

  def secret(name) do
    case System.get_env(name, "") |> String.trim() do
      "" -> nil
      text -> text
    end
  end
end

{opts, args, invalid} = OptionParser.parse(System.argv(), strict: [keys: :string])

{version, dir} =
  case {args, invalid} do
    {[version, dir], []} ->
      {version, dir}

    _ ->
      ReleaseManifest.fail("usage: elixir scripts/release-manifest.exs VERSION DIR [--keys FILE]")
  end

unless Regex.match?(~r/\A[0-9A-Za-z.+-]+\z/, version),
  do: ReleaseManifest.fail("#{version} is not a version")

unless File.dir?(dir), do: ReleaseManifest.fail("#{dir} is not a directory")

keys_path = opts[:keys] || Path.join(root, "apps/troupe_core/priv/release-keys.txt")

keys =
  case Minisign.parse_key_list(File.read!(keys_path)) do
    {:ok, []} ->
      ReleaseManifest.fail(
        "#{keys_path} holds no release key: add the public half of the release key first " <>
          "(docs/developer/ci.md, \"The release key\"); a release is never published unsigned"
      )

    {:ok, keys} ->
      keys

    {:error, why} ->
      ReleaseManifest.fail("#{keys_path}: #{why}")
  end

primary =
  case ReleaseManifest.secret("RELEASE_MINISIGN_KEY") do
    nil ->
      ReleaseManifest.fail(
        "RELEASE_MINISIGN_KEY is not set: the release environment's secret holds the release key, " <>
          "and a release is never published unsigned (docs/developer/ci.md, \"The release key\")"
      )

    text ->
      case Minisign.parse_secret_key(text) do
        {:ok, secret} -> secret
        {:error, why} -> ReleaseManifest.fail("RELEASE_MINISIGN_KEY #{why}")
      end
  end

unless Minisign.public_key(primary) == hd(keys) do
  id = Minisign.key_id(primary)

  ReleaseManifest.fail(
    if Minisign.public_key(primary) in keys,
      do:
        "RELEASE_MINISIGN_KEY is key #{id}, which is in #{keys_path} but not first: the first is the key a release is signed with",
      else:
        "RELEASE_MINISIGN_KEY is key #{id}, which is not in #{keys_path}: no client would trust what it signs"
  )
end

previous =
  case ReleaseManifest.secret("RELEASE_MINISIGN_KEY_PREVIOUS") do
    nil ->
      []

    text ->
      with {:ok, secret} <- Minisign.parse_secret_key(text),
           true <- Minisign.public_key(secret) in tl(keys) do
        [secret]
      else
        {:error, why} ->
          ReleaseManifest.fail("RELEASE_MINISIGN_KEY_PREVIOUS #{why}")

        false ->
          ReleaseManifest.fail(
            "RELEASE_MINISIGN_KEY_PREVIOUS is not one of the other keys in #{keys_path}"
          )
      end
  end

manifest = Manifest.build(version, dir)
if manifest.artifacts == [], do: ReleaseManifest.fail("#{dir} holds no file to sign")

bytes = Manifest.encode(manifest)
trusted = "timestamp:#{System.os_time(:second)}\tfile:manifest.json\tversion:#{version}"

signature =
  Enum.map_join([primary | previous], &Minisign.sign(bytes, &1, trusted_comment: trusted))

# The clients' own check, against the list they are built with, before anything is written.
case Minisign.verify(bytes, signature, keys) do
  {:ok, %{key_ids: ids}} ->
    File.write!(Path.join(dir, "manifest.json"), bytes)
    File.write!(Path.join(dir, "manifest.json.minisig"), signature)

    IO.puts(
      "manifest.json: #{length(manifest.artifacts)} files of #{version}, signed by key #{Enum.join(ids, " and ")}"
    )

  {:error, why} ->
    ReleaseManifest.fail("the manifest #{why}")
end
