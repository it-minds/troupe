# Every third-party package this repository locks, and the licence each one declares.
#
#     elixir scripts/licences.exs            # write docs/third-party-licences.md
#     elixir scripts/licences.exs --check    # exit 1 on a refused licence or a stale document
#
# Troupe is Apache-2.0 so that anyone can build on it, in the open or not, and that stays
# true only while nothing it depends on asks for more. A copyleft dependency - the GPL
# family, AGPL, SSPL - would turn the licence into a promise the project cannot keep, and
# it arrives the way every dependency does: as a line in a lock file nobody reads. So CI
# runs `--check` on every pull request (`.github/workflows/licences.yml`), and the policy
# it applies is below.
#
# Three ecosystems, each read through its own tool, so each needs its packages first:
#
#   * the umbrella's and the TUI's Mix locks: `mix deps.get` at the root and in
#     `clients/tui`. A Hex package's licence is in `deps/<name>/hex_metadata.config`, a git
#     dependency's in its `src/<name>.app.src`.
#   * the GUI's pnpm workspace: `pnpm install` in `clients/gui`, then `pnpm licenses list`.
#   * the desktop app's crates: `cargo metadata`, which fetches what it needs.
#
# The document lists a package once per licence and leaves versions to the locks: a list
# that changed with every bump would be regenerated without being read. It changes when a
# package arrives, leaves or changes licence, which is when somebody should look.

defmodule Licences do
  @root Path.expand("..", __DIR__)
  @document "docs/third-party-licences.md"
  @gui "clients/gui"
  @crate "clients/gui/apps/desktop/src-tauri/Cargo.toml"

  # Permissive licences: use, change and ship, open or closed, keeping the notice. A package
  # under one of these, or under an expression that lets us pick one (`MIT OR GPL-2.0` is
  # fine), passes without review. Add a licence here only if it asks for nothing more.
  @allowed ~w(0BSD Apache-2.0 BlueOak-1.0.0 BSD-2-Clause BSD-3-Clause BSL-1.0 CC0-1.0
              CDLA-Permissive-2.0 ISC MIT MIT-0 Unicode-3.0 Unlicense Zlib)

  # Hex does not insist on SPDX identifiers. The spellings the locked packages use.
  @aliases %{"Apache 2.0" => "Apache-2.0", "BSD 2-Clause" => "BSD-2-Clause"}

  @operators ~w[AND OR WITH ( )]

  # Everything else - the GPL family, AGPL, LGPL, SSPL, EUPL, MPL, a font or data licence,
  # a licence missing or unreadable - fails the check until a person has reviewed that
  # package under that licence and recorded it here. The reason answers three questions:
  #
  #   * what the licence asks of whoever ships it: publish our source, publish changes to
  #     its files, carry its notice, keep it under its own terms;
  #   * whether it ships at all (a release, an image, the desktop app) or only builds and
  #     tests something;
  #   * whether we change it. A package we patch is a different question from one we use.
  #
  # The pull request that adds an entry is where a maintainer approves it. An entry names
  # the licence exactly as the package declares it, so a package that changes licence
  # fails again; an entry that matches nothing any more fails too, and is deleted.
  @exceptions [
    {:cargo, "cssparser", "MPL-2.0",
     "Tauri's HTML handling, through `tauri-utils`, in the desktop app. MPL-2.0 is copyleft " <>
       "per file: we use it unmodified, as crates.io publishes it with its source, and a " <>
       "change to its files would have to be published under MPL-2.0."},
    {:cargo, "cssparser-macros", "MPL-2.0", "`cssparser`'s macros. As `cssparser`."},
    {:cargo, "dtoa-short", "MPL-2.0", "Used by `cssparser`. As `cssparser`."},
    {:cargo, "selectors", "MPL-2.0", "Tauri's HTML handling, with `cssparser`. As `cssparser`."},
    {:cargo, "option-ext", "MPL-2.0", "Tauri's `dirs`, through `dirs-sys`. As `cssparser`."},
    {:pnpm, "@fontsource/ibm-plex-mono", "OFL-1.1",
     "The IBM Plex fonts the GUI ships. OFL-1.1 allows bundling a font with software; " <>
       "the font stays under it, unchanged and never sold on its own."},
    {:pnpm, "@fontsource/ibm-plex-sans", "OFL-1.1", "As `@fontsource/ibm-plex-mono`."},
    {:pnpm, "caniuse-lite", "CC-BY-4.0",
     "Browser-support data the GUI's build tools read. It does not ship."}
  ]

  @headings %{
    hex: "Elixir: the umbrella and the TUI (Hex)",
    pnpm: "The GUI (pnpm)",
    cargo: "The desktop app (Cargo)"
  }

  def main([]) do
    packages = packages()
    File.write!(Path.join(@root, @document), render(packages))
    IO.puts("wrote #{@document}: #{count(packages)} packages")
  end

  def main(["--check"]), do: check(packages())

  def main(_) do
    IO.puts(:stderr, "usage: elixir scripts/licences.exs [--check]")
    System.halt(2)
  end

  defp packages, do: hex() ++ pnpm() ++ cargo()

  defp check(packages) do
    document = render(packages)

    # The two Mix locks share most of their packages, so a refusal can come twice.
    refused =
      for p <- packages, not acceptable?(p.expression), not excepted?(p), uniq: true do
        "#{p.ecosystem} #{p.name} #{p.version}: #{p.licence || "no licence declared"}"
      end

    unused =
      for {ecosystem, name, licence, _} = exception <- @exceptions,
          not Enum.any?(packages, &covers?(exception, &1)) do
        "exception for #{ecosystem} #{name} (#{licence}) matches no package: delete it"
      end

    stale =
      case File.read(Path.join(@root, @document)) do
        {:ok, ^document} -> []
        _ -> ["#{@document} is not current: run `elixir scripts/licences.exs` and commit it"]
      end

    for line <- refused, do: IO.puts(:stderr, "refused: #{line}")
    for line <- unused ++ stale, do: IO.puts(:stderr, line)

    case {refused, unused ++ stale} do
      {[], []} ->
        IO.puts("licences allowed: #{count(packages)} packages, #{length(@exceptions)} excepted")

      {[], _} ->
        System.halt(1)

      _ ->
        IO.puts(:stderr, """
        #{length(refused)} package(s) under a licence the policy does not allow. Use another
        package, or have one reviewed: the policy and how to record an exception are at
        the top of scripts/licences.exs.
        """)

        System.halt(1)
    end
  end

  defp count(packages), do: packages |> Enum.uniq_by(&{&1.ecosystem, &1.name}) |> length()

  defp excepted?(p), do: Enum.any?(@exceptions, &covers?(&1, p))

  defp covers?({ecosystem, name, licence, _why}, p),
    do: ecosystem == p.ecosystem and name == p.name and licence == p.licence

  # -- Hex ------------------------------------------------------------------------------

  defp hex do
    for {lock, deps} <- [{"mix.lock", "deps"}, {"clients/tui/mix.lock", "clients/tui/deps"}],
        {key, entry} <- read_lock(lock) do
      name = Atom.to_string(key)
      dir = Path.join([@root, deps, name])

      unless File.dir?(dir) do
        fail("#{deps}/#{name} is not there: run `mix deps.get` in #{Path.dirname(lock)}")
      end

      declared = declared_licences(entry, dir)

      %{
        ecosystem: :hex,
        name: name,
        version: elem(entry, 2),
        licence: if(declared == [], do: nil, else: Enum.join(declared, ", ")),
        # Several are read as all of them: Hex gives a list no meaning, so assume the most.
        expression: declared |> Enum.map(&Map.get(@aliases, &1, &1)) |> Enum.join(" AND "),
        listed: true
      }
    end
  end

  # Read the way `Mix.Dep.Lock` reads it, as `scripts/locks-agree.exs` does.
  defp read_lock(path) do
    opts = [file: path, emit_warnings: false]
    {:ok, quoted} = Path.join(@root, path) |> File.read!() |> Code.string_to_quoted(opts)
    {lock, _binding} = Code.eval_quoted(quoted, [], opts)
    lock
  end

  defp declared_licences(entry, dir) when elem(entry, 0) == :hex do
    {:ok, terms} = :file.consult(String.to_charlist(Path.join(dir, "hex_metadata.config")))
    terms |> List.keyfind("licenses", 0, {"licenses", []}) |> elem(1)
  end

  defp declared_licences(entry, dir) when elem(entry, 0) == :git do
    case Path.wildcard(Path.join(dir, "src/*.app.src")) do
      [app_src] ->
        {:ok, [{:application, _, props}]} = :file.consult(String.to_charlist(app_src))
        props |> Keyword.get(:licenses, []) |> Enum.map(&to_string/1)

      _ ->
        []
    end
  end

  # -- pnpm -----------------------------------------------------------------------------

  defp pnpm do
    json = run("pnpm", ["licenses", "list", "--json"], @gui, "run `pnpm install` in #{@gui}")

    for {_licence, entries} <- JSON.decode!(json),
        %{"name" => name, "license" => licence} = entry <- entries,
        {version, path} <- Enum.zip(entry["versions"], entry["paths"]),
        not own?(name) do
      %{
        ecosystem: :pnpm,
        name: name,
        version: version,
        licence: licence,
        expression: licence,
        listed: not platform_build?(path)
      }
    end
  end

  defp own?(name), do: name == "troupe-gui" or String.starts_with?(name, "@troupe/")

  # esbuild's, Rollup's and the Tauri CLI's binaries for one operating system and processor.
  # Which ones are installed depends on the machine, so they are checked and not listed.
  defp platform_build?(path) do
    manifest = path |> Path.join("package.json") |> File.read!() |> JSON.decode!()
    Map.has_key?(manifest, "os") or Map.has_key?(manifest, "cpu")
  end

  # -- Cargo ----------------------------------------------------------------------------

  defp cargo do
    args = ["metadata", "--format-version", "1", "--locked", "--manifest-path", @crate]
    json = run("cargo", args, ".", "install Rust (rustup.rs)")

    # A package with no source is a path dependency: ours.
    for %{"source" => source} = crate <- JSON.decode!(json)["packages"], source != nil do
      %{
        ecosystem: :cargo,
        name: crate["name"],
        version: crate["version"],
        licence: crate["license"],
        expression: crate["license"],
        listed: true
      }
    end
  end

  defp run(command, args, dir, hint) do
    path = System.find_executable(command) || fail("#{command} is not on the PATH: #{hint}")
    opts = [cd: Path.join(@root, dir)]

    # Windows will not start `pnpm.cmd` as a program (`:eacces`); `cmd.exe` will. The
    # arguments here are plain words, so the line needs no quoting.
    result =
      if String.downcase(Path.extname(path)) in [".cmd", ".bat"],
        do: System.shell(Enum.join([command | args], " "), opts),
        else: System.cmd(path, args, opts)

    case result do
      {out, 0} ->
        out

      {out, status} ->
        fail("#{command} #{Enum.join(args, " ")} exited #{status} (#{hint}):\n#{out}")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  # -- The policy -----------------------------------------------------------------------

  @doc """
  Whether an SPDX expression can be satisfied from `@allowed`: `OR` needs one side, `AND`
  both, and `X WITH exception` whatever `X` needs, since an exception only grants more.
  The older `MIT/Apache-2.0` is read as `OR`. Anything that does not parse is refused.
  """
  def acceptable?(nil), do: false

  def acceptable?(expression) do
    tokens =
      expression
      |> String.replace("/", " OR ")
      |> String.replace("(", " ( ")
      |> String.replace(")", " ) ")
      |> String.split()
      |> Enum.map(&if(String.upcase(&1) in ~w(AND OR WITH), do: String.upcase(&1), else: &1))

    case any(tokens) do
      {value, []} -> value
      _ -> false
    end
  rescue
    _ -> false
  end

  defp any(tokens) do
    case all(tokens) do
      {left, ["OR" | rest]} ->
        {right, rest} = any(rest)
        {left or right, rest}

      result ->
        result
    end
  end

  defp all(tokens) do
    case term(tokens) do
      {left, ["AND" | rest]} ->
        {right, rest} = all(rest)
        {left and right, rest}

      result ->
        result
    end
  end

  defp term(["(" | rest]) do
    {value, [")" | rest]} = any(rest)
    {value, rest}
  end

  defp term([id, "WITH", _exception | rest]) when id not in @operators, do: {id in @allowed, rest}
  defp term([id | rest]) when id not in @operators, do: {id in @allowed, rest}

  # -- The document ---------------------------------------------------------------------

  defp render(packages) do
    sections =
      for ecosystem <- [:hex, :pnpm, :cargo] do
        rows =
          packages
          |> Enum.filter(&(&1.ecosystem == ecosystem and &1.listed))
          |> Enum.map(&{&1.name, &1.licence || "none declared"})
          |> Enum.uniq()
          |> Enum.sort()

        names = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()

        """
        ## #{@headings[ecosystem]}

        #{about(ecosystem, names)}
        | package | licence |
        |---|---|
        #{Enum.map_join(rows, "\n", fn {name, licence} -> "| `#{name}` | #{licence} |" end)}
        """
      end

    exceptions =
      Enum.map_join(@exceptions, "\n", fn {ecosystem, name, licence, why} ->
        "| #{ecosystem} | `#{name}` | #{licence} | #{why} |"
      end)

    """
    # Third-party licences

    <!-- Generated by `elixir scripts/licences.exs`. Do not edit: the packages come from the
         lock files, each licence from the package's own metadata, and the policy is in the
         script. -->

    Every third-party package this repository locks, with the licence the package itself
    declares. Troupe is Apache-2.0 ([LICENSE](../LICENSE), [NOTICE](../NOTICE)).

    CI regenerates this on every pull request and fails when it differs from what is
    committed, or when a package is under a licence the policy at the top of
    [scripts/licences.exs](../scripts/licences.exs) does not allow: permissive licences
    pass, and anything else needs a reviewed exception. A package is listed once for each
    licence it has at the versions locked; the versions are in the lock files.

    Not listed, because no lock file names them: what a build puts into a binary from
    outside a package manager, such as the Erlang/OTP runtime every release carries
    (Apache-2.0) and the zstd library that `ezstd` compiles into its NIF (BSD-3-Clause OR
    GPL-2.0-only, used under BSD-3-Clause).

    ## Reviewed exceptions

    | from | package | licence | why it is allowed |
    |---|---|---|---|
    #{exceptions}

    #{Enum.join(sections, "\n")}\
    """
  end

  defp about(:hex, names) do
    """
    #{names} packages, from `mix.lock` and `clients/tui/mix.lock`, development and test
    tools included.
    """
  end

  defp about(:pnpm, names) do
    """
    #{names} packages, from `clients/gui/pnpm-lock.yaml`, build and test tools included. A
    package's builds for one operating system and processor, such as esbuild's, are checked
    and not listed: each is under its parent's licence, and which of them are installed
    depends on the machine.
    """
  end

  defp about(:cargo, names) do
    """
    #{names} crates, from `clients/gui/apps/desktop/src-tauri/Cargo.lock`, for every
    platform, build dependencies included.
    """
  end
end

Licences.main(System.argv())
