# The release signature's test vectors (#66, Decision 865), written to
# test/fixtures/release/ for every verifier of a release to run: this repository's
# (Troupe.Release.Minisign, apps/troupe_core/test/troupe/release/vectors_test.exs) and, when
# it comes, the desktop app's.
#
#   elixir scripts/release-vectors.exs [DIR]
#
# vectors.json lists the cases: a manifest, a signature, the keys a client trusts, and
# whether it accepts them; then files to check against the manifest. Every key is made here,
# held in memory, and gone when this exits: only the public halves and what they signed are
# written, and none of them is a release key. Run again, it writes a new set with new keys.
root = Path.expand("..", __DIR__)

for file <- ~w(minisign.ex manifest.ex) do
  Code.require_file(Path.join(root, "apps/troupe_protocol/lib/troupe/release/#{file}"))
end

alias Troupe.Release.{Manifest, Minisign}

dir = Path.expand(List.first(System.argv()) || Path.join(root, "test/fixtures/release"))
File.rm_rf!(dir)
for sub <- ~w(keys signatures artifacts tampered short), do: File.mkdir_p!(Path.join(dir, sub))

version = "9.9.9-test"
artifact = "troupe-#{version}-linux_x86_64"
content = "troupe #{version}, for the release test vectors\n"
File.write!(Path.join([dir, "artifacts", artifact]), content)
# One byte changed, and one byte fewer.
File.write!(
  Path.join([dir, "tampered", artifact]),
  String.replace(content, "troupe", "trouPe", global: false)
)

File.write!(Path.join([dir, "short", artifact]), String.slice(content, 0..-3//1) <> "\n")

keys = for name <- ~w(current previous other), into: %{}, do: {name, Minisign.generate_keypair()}

for {name, {public, _secret}} <- keys do
  File.write!(Path.join([dir, "keys", "#{name}.pub"]), Minisign.public_key_file(public))
end

secret = fn name -> elem(keys[name], 1) end
manifest = Manifest.encode(Manifest.build(version, Path.join(dir, "artifacts")))
File.write!(Path.join(dir, "manifest.json"), manifest)

File.write!(
  Path.join(dir, "manifest-tampered.json"),
  String.replace(manifest, version, "9.9.8-test")
)

trusted = "timestamp:1760000000\tfile:manifest.json\tversion:#{version}"

sign = fn name, opts ->
  Minisign.sign(manifest, secret.(name), Keyword.put_new(opts, :trusted_comment, trusted))
end

current = sign.("current", [])

[comment, line, _trusted, global] = String.split(current, "\n", trim: true)

signatures = %{
  "current" => current,
  "rotation" => current <> sign.("previous", []),
  "previous" => sign.("previous", []),
  "other" => sign.("other", []),
  "legacy" => sign.("current", legacy: true),
  "comment-changed" =>
    Enum.join(
      [
        comment,
        line,
        "trusted comment: " <> String.replace(trusted, version, "9.9.8-test"),
        global
      ],
      "\n"
    ) <> "\n",
  "empty" => "",
  "not-minisign" => "untrusted comment: not a signature\nnot base64 at all\n"
}

for {name, text} <- signatures,
    do: File.write!(Path.join([dir, "signatures", "#{name}.minisig"]), text)

case_line = fn fields -> "    " <> JSON.encode!(Map.new(fields)) end

signature_cases = [
  {"signed by the current key", "manifest.json", "current", ~w(current), "ok"},
  {"a key rotation: both keys sign, the current first; a client built after it", "manifest.json",
   "rotation", ~w(current), "ok"},
  {"a key rotation, read by a client built before it, which trusts only the previous key",
   "manifest.json", "rotation", ~w(previous), "ok"},
  {"a key rotation, read by a client that trusts both", "manifest.json", "rotation",
   ~w(current previous), "ok"},
  {"signed by the previous key alone, read by a client that trusts only the current one",
   "manifest.json", "previous", ~w(current), "refused"},
  {"the minisign signature without a hash (\"Ed\"), which minisign once wrote", "manifest.json",
   "legacy", ~w(current), "ok"},
  {"the manifest changed after it was signed", "manifest-tampered.json", "current", ~w(current),
   "refused"},
  {"signed by a key the client does not trust", "manifest.json", "other", ~w(current), "refused"},
  {"the trusted comment changed after it was signed", "manifest.json", "comment-changed",
   ~w(current), "refused"},
  {"no signature: an empty .minisig", "manifest.json", "empty", ~w(current), "refused"},
  {"a .minisig that is not minisign's", "manifest.json", "not-minisign", ~w(current), "refused"},
  {"a client that trusts no key", "manifest.json", "current", [], "refused"}
]

signature_lines =
  Enum.map(signature_cases, fn {name, manifest_file, signature, trusting, expect} ->
    case_line.(
      name: name,
      manifest: manifest_file,
      signature: "signatures/#{signature}.minisig",
      trusted: Enum.map(trusting, &"keys/#{&1}.pub"),
      expect: expect
    )
  end)

artifact_lines =
  for {name, file, expect} <- [
        {"the artifact as the manifest names it", "artifacts/#{artifact}", "ok"},
        {"one byte changed: the size holds, the sha256 does not", "tampered/#{artifact}",
         "refused"},
        {"one byte short: the size does not hold", "short/#{artifact}", "refused"}
      ] do
    case_line.(
      name: name,
      manifest: "manifest.json",
      artifact: artifact,
      file: file,
      expect: expect
    )
  end

File.write!(Path.join(dir, "vectors.json"), """
{
  "about": "Test vectors for a release's signed manifest (Decision 865), written by scripts/release-vectors.exs with throwaway keys. A verifier accepts a case whose expect is ok and refuses the rest: a signature case checks signature against manifest with only the trusted keys; an artifact case checks file against the manifest's entry for artifact, its size and then its sha256.",
  "signatures": [
#{Enum.join(signature_lines, ",\n")}
  ],
  "artifacts": [
#{Enum.join(artifact_lines, ",\n")}
  ]
}
""")

IO.puts("wrote the release test vectors to #{dir}")
