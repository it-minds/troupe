# The signing test's last step (signing.yml): the manifest a release publishes names exactly
# the files the native builds OS-signed.
#
#   elixir scripts/signing/check-manifest.exs VERSION DIR RECORDS...
#
# DIR holds the native builds' artifacts as they were uploaded, in subdirectories or not;
# each RECORDS file holds `sha256  name` lines, written by a build once the signatures of
# the files named had been checked (`scripts/signing/ci.sh record`). The artifacts are
# laid out flat, as the release holds them, and `scripts/release-manifest.exs` signs their
# manifest with a throwaway key made here, exactly as `release.yml`'s publish job does with
# the release key. Then:
#
#   - the signature verifies, with the clients' own verifier;
#   - every recorded file is in the manifest with the recorded sha256, so what the release
#     key signs is the signed file and not one from before it was signed;
#   - every file the manifest names for a Mac or a Windows machine is recorded, so nothing
#     those machines run is published unsigned.
root = Path.expand("../..", __DIR__)

for file <- ~w(minisign.ex manifest.ex) do
  Code.require_file(Path.join(root, "apps/troupe_protocol/lib/troupe/release/#{file}"))
end

alias Troupe.Release.{Manifest, Minisign}

fail = fn message ->
  IO.puts(:stderr, "check-manifest: " <> message)
  System.halt(1)
end

{version, dir, record_files} =
  case System.argv() do
    [version, dir | records] when records != [] -> {version, dir, records}
    _ -> fail.("usage: elixir scripts/signing/check-manifest.exs VERSION DIR RECORDS...")
  end

tmp = Path.join(System.tmp_dir!(), "check-manifest-#{System.unique_integer([:positive])}")
flat = Path.join(tmp, "release")
File.mkdir_p!(flat)

for path <- Path.wildcard(Path.join(Path.expand(dir), "**"), match_dot: true),
    File.regular?(path) do
  target = Path.join(flat, Path.basename(path))
  if File.exists?(target), do: fail.("two artifacts are named #{Path.basename(path)}")
  File.cp!(path, target)
end

{public, secret} = Minisign.generate_keypair()
keys = Path.join(tmp, "release-keys.txt")
File.write!(keys, "# the signing test's throwaway key\n#{Minisign.encode_public_key(public)}\n")

{out, status} =
  System.cmd(
    System.find_executable("elixir") || fail.("no elixir on the PATH"),
    [Path.join(root, "scripts/release-manifest.exs"), version, flat, "--keys", keys],
    env: [
      {"RELEASE_MINISIGN_KEY", Minisign.encode_secret_key(secret)},
      {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}
    ],
    stderr_to_stdout: true
  )

IO.write(out)
if status != 0, do: fail.("scripts/release-manifest.exs exited #{status}")

bytes = File.read!(Path.join(flat, "manifest.json"))

case Minisign.verify(bytes, File.read!(Path.join(flat, "manifest.json.minisig")), [public]) do
  {:ok, _} -> :ok
  {:error, why} -> fail.("the manifest's signature does not verify: #{why}")
end

{:ok, manifest} = Manifest.decode(bytes)
by_file = Map.new(manifest.artifacts, &{&1.file, &1})

records =
  for path <- record_files,
      line <- String.split(File.read!(path), ~r/\r?\n/, trim: true),
      into: %{} do
    case String.split(String.trim(line), ~r/\s+/, parts: 2) do
      [sha, name] -> {name, String.downcase(sha)}
      _ -> fail.("#{path}: #{inspect(line)} is not `sha256  name`")
    end
  end

if records == %{}, do: fail.("no build recorded a signed file")

problems =
  Enum.flat_map(records, fn {name, sha} ->
    case by_file[name] do
      nil ->
        ["#{name} was signed but the manifest does not name it"]

      %{sha256: ^sha} ->
        []

      %{sha256: other} ->
        ["#{name}: the manifest's sha256 #{other} is not the signed file's #{sha}"]
    end
  end) ++
    for a <- manifest.artifacts,
        a.component in ~w(daemon tui desktop),
        is_binary(a.target) and not String.starts_with?(a.target, "linux"),
        not Map.has_key?(records, a.file) do
      "#{a.file} (#{a.component}, #{a.target}) is in the manifest, but no build recorded it signed"
    end

summary = System.get_env("GITHUB_STEP_SUMMARY")

if problems != [] do
  Enum.each(problems, &IO.puts(:stderr, "  " <> &1))
  fail.("the manifest and what was signed disagree (#{length(problems)})")
end

lines =
  for {name, sha} <- Enum.sort(records) do
    "- `#{name}`: signed, and in the signed manifest as `#{binary_part(sha, 0, 12)}…`"
  end

IO.puts(Enum.join(lines, "\n"))

if summary,
  do:
    File.write!(
      summary,
      "### The manifest names the signed files\n\n" <> Enum.join(lines, "\n") <> "\n",
      [:append]
    )

IO.puts("manifest.json: #{map_size(records)} signed files, each named with its signed sha256")
