# The one version, and every file that has to repeat it.
#
#     elixir scripts/version.exs check          # every file agrees with VERSION, or exit 1
#     elixir scripts/version.exs set 0.3.0      # write it everywhere, VERSION included
#
# `VERSION` is the version of everything this repository releases (Decision 668): the
# umbrella's apps and the daemon read it directly, and so does the TUI. These are the files
# that cannot read it and carry a copy — the chart, the GUI's packages, the desktop app —
# and a copy nobody checks is how four numbers came to have no relation to each other.
#
# The desktop app gets the version without its pre-release part. Windows installers (WiX)
# refuse a pre-release identifier that is not a number, so `0.3.0-rc.1` would fail the MSI
# build; a release candidate's desktop build says `0.3.0`, and its file names still carry
# the full version because the release workflow names them.
#
# Edits are to the one line that holds the version in each file, so formatting is left as
# it is.

defmodule Version.Files do
  @root Path.expand("..", __DIR__)

  # {path, pattern capturing the version, which version it should hold}
  def files do
    [
      {"charts/troupe/Chart.yaml", ~r/^version: (.+)$/m, :full},
      {"charts/troupe/Chart.yaml", ~r/^appVersion: "(.+)"$/m, :full},
      {"clients/gui/packages/client/package.json", ~r/^  "version": "(.+)",$/m, :full},
      {"clients/gui/packages/bench/package.json", ~r/^  "version": "(.+)",$/m, :full},
      {"clients/gui/apps/desktop/package.json", ~r/^  "version": "(.+)",$/m, :full},
      {"clients/gui/apps/desktop/src-tauri/tauri.conf.json", ~r/^  "version": "(.+)",$/m, :base},
      {"clients/gui/apps/desktop/src-tauri/Cargo.toml", ~r/\A\[package\]\nname = "troupe-desktop"\nversion = "(.+)"$/m, :base},
      {"clients/gui/apps/desktop/src-tauri/Cargo.lock", ~r/^name = "troupe-desktop"\nversion = "(.+)"$/m, :base}
    ]
  end

  def read_version, do: @root |> Path.join("VERSION") |> File.read!() |> String.trim()

  def expected(version, :full), do: version
  def expected(version, :base), do: version |> String.split("-", parts: 2) |> hd()

  def current(path, pattern) do
    case Regex.run(pattern, File.read!(Path.join(@root, path)), capture: :all_but_first) do
      [value] -> {:ok, value}
      nil -> {:error, "no version line matched"}
    end
  end

  def set(path, pattern, value) do
    full = Path.join(@root, path)
    contents = File.read!(full)

    [{start, length}] = Regex.run(pattern, contents, return: :index, capture: :all_but_first)
    updated = binary_part(contents, 0, start) <> value <> binary_part(contents, start + length, byte_size(contents) - start - length)
    File.write!(full, updated)
  end

  def root, do: @root
end

valid? = fn version -> Regex.match?(~r/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/, version) end

case System.argv() do
  ["check"] ->
    version = Version.Files.read_version()

    problems =
      for {path, pattern, kind} <- Version.Files.files(),
          want = Version.Files.expected(version, kind),
          result = Version.Files.current(path, pattern),
          result != {:ok, want} do
        case result do
          {:ok, got} -> "#{path}: #{got}, expected #{want}"
          {:error, why} -> "#{path}: #{why}"
        end
      end

    case problems do
      [] ->
        IO.puts("versions agree: #{version} in VERSION and #{length(Version.Files.files())} copies")

      _ ->
        Enum.each(problems, &IO.puts(:stderr, &1))
        IO.puts(:stderr, "run `elixir scripts/version.exs set #{version}` and commit the result")
        System.halt(1)
    end

  ["set", version] ->
    unless valid?.(version), do: raise("#{inspect(version)} is not a version (MAJOR.MINOR.PATCH, optionally -PRERELEASE)")
    File.write!(Path.join(Version.Files.root(), "VERSION"), version <> "\n")

    for {path, pattern, kind} <- Version.Files.files() do
      Version.Files.set(path, pattern, Version.Files.expected(version, kind))
    end

    IO.puts("VERSION and #{length(Version.Files.files())} copies set to #{version}")

  _ ->
    IO.puts(:stderr, "usage: elixir scripts/version.exs check | set <version>")
    System.halt(2)
end
