# Every third-party package this repository locks, the licence each one declares, and the
# licence texts that travel with what Troupe ships.
#
#     elixir scripts/licences.exs            # write the documents below
#     elixir scripts/licences.exs --check    # exit 1 on a refused licence or a stale document
#
# It writes three things, and `--check` fails when any of them is not what it would write:
#
#   * `docs/third-party-licences.md`, the inventory: every package, its licence, and the
#     exceptions the policy below allows.
#   * `THIRD-PARTY-NOTICES.txt`, the texts: each shipped package's own LICENSE, COPYING and
#     NOTICE files, or the standard text of the licence it declares when it ships none
#     (`scripts/licence-texts/`, from SPDX), and where the source of an MPL-2.0 package is.
#     Apache-2.0, MIT and BSD ask that these go with every binary copy, so every release
#     artifact carries this file beside LICENSE and NOTICE: the daemon's archive, the TUI's
#     binary, the desktop app, the images and the release page.
#   * `charts/troupe/LICENSE` and `charts/troupe/NOTICE`, copies of the root's: the chart is
#     packaged from its own directory.
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
# package arrives, leaves or changes licence, which is when somebody should look. The
# notices name no versions either, so they change when a package's own texts do.

defmodule Licences do
  @root Path.expand("..", __DIR__)
  @document "docs/third-party-licences.md"
  @notices "THIRD-PARTY-NOTICES.txt"
  @texts "scripts/licence-texts"
  @copies [{"charts/troupe/LICENSE", "LICENSE"}, {"charts/troupe/NOTICE", "NOTICE"}]
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

  # Licences that ask whoever ships a binary to say where its source is: MPL-2.0's section
  # 3.2. The notices name the exact source of every package under one of them.
  @source_offered ~w(MPL-2.0)

  @headings %{
    hex: "Elixir: the umbrella and the TUI (Hex)",
    pnpm: "The GUI (pnpm)",
    cargo: "The desktop app (Cargo)"
  }

  def main([]) do
    {packages, shipped} = packages()

    for {path, contents} <- outputs(packages, shipped) do
      File.write!(Path.join(@root, path), contents)
    end

    IO.puts(
      "wrote #{@document} (#{count(packages)} packages), #{@notices} and the chart's copies"
    )
  end

  def main(["--check"]), do: check(packages())

  def main(_) do
    IO.puts(:stderr, "usage: elixir scripts/licences.exs [--check]")
    System.halt(2)
  end

  # Every package, which is what the policy reads, and the ones whose texts ship. They
  # differ only in the GUI: its build and test tools are pnpm packages too, and none of
  # them ends up in its bundle.
  defp packages do
    hex = hex()
    cargo = cargo()
    {hex ++ pnpm([]) ++ cargo, hex ++ pnpm(["--prod"]) ++ cargo}
  end

  defp outputs(packages, shipped) do
    copies = for {copy, original} <- @copies, do: {copy, File.read!(Path.join(@root, original))}
    [{@document, render(packages)}, {@notices, notices(shipped)} | copies]
  end

  defp check({packages, shipped}) do
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
      for {path, contents} <- outputs(packages, shipped),
          File.read(Path.join(@root, path)) != {:ok, contents} do
        "#{path} is not current: run `elixir scripts/licences.exs` and commit it"
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
        listed: true,
        dir: dir
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

  # `--prod` is what the GUI's bundle is made from: the packages it depends on to run.
  defp pnpm(only) do
    args = ["licenses", "list", "--json" | only]
    json = run("pnpm", args, @gui, "run `pnpm install` in #{@gui}")

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
        listed: not platform_build?(path),
        dir: path
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
        listed: true,
        dir: Path.dirname(crate["manifest_path"]),
        # `license-file`: a crate under a licence with no SPDX name says where its text is.
        licence_file: crate["license_file"]
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
    case expression |> tokens() |> any() do
      {value, []} -> value
      _ -> false
    end
  rescue
    _ -> false
  end

  defp tokens(expression) do
    expression
    |> String.replace("/", " OR ")
    |> String.replace("(", " ( ")
    |> String.replace(")", " ) ")
    |> String.split()
    |> Enum.map(&if(String.upcase(&1) in ~w(AND OR WITH), do: String.upcase(&1), else: &1))
  end

  # The licences an expression names, without the exceptions after `WITH`.
  defp ids(nil), do: []
  defp ids(expression), do: expression |> tokens() |> named([]) |> Enum.reverse() |> Enum.uniq()

  defp named([], acc), do: acc
  defp named(["WITH", _exception | rest], acc), do: named(rest, acc)
  defp named([token | rest], acc) when token in @operators, do: named(rest, acc)
  defp named([id | rest], acc), do: named(rest, [id | acc])

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
    declares. Troupe is Apache-2.0 ([LICENSE](../LICENSE), [NOTICE](../NOTICE)). The
    licence texts, as the shipped packages carry them, are in
    [THIRD-PARTY-NOTICES.txt](../THIRD-PARTY-NOTICES.txt), which every release artifact
    carries too.

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

  # -- The notices ----------------------------------------------------------------------

  @order %{hex: 0, pnpm: 1, cargo: 2}
  @kinds %{hex: "Hex packages", pnpm: "npm packages", cargo: "Rust crates"}
  @rule String.duplicate("=", 88)
  @thin String.duplicate("-", 88)

  # A licence file at a package's root, by the names packages give them: LICENSE,
  # LICENSE-MIT, LICENCE.txt, COPYING, NOTICE, UNLICENSE and so on.
  @licence_file ~r/^(licen[cs]e|copying|copyright|notice|unlicen[cs]e)([-._ ].*)?$/i

  defp notices(packages) do
    packages = packages |> Enum.filter(& &1.listed) |> Enum.sort_by(&sort_key/1)

    # One block per text, whoever ships it: most of a crate graph shares a handful of
    # Apache-2.0 and MIT texts. Texts that differ only in their spacing are one text, and
    # the one printed is the first package's.
    blocks =
      packages
      |> Enum.flat_map(fn p ->
        for {kind, text} <- texts(p), do: {{kind, squeeze(text)}, text, p}
      end)
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {{kind, squeezed}, [{_, text, _} | _] = entries} ->
        shippers = entries |> Enum.map(&elem(&1, 2)) |> Enum.uniq_by(&{&1.ecosystem, &1.name})
        {{sort_key(hd(shippers)), kind, squeezed}, block(kind, text, shippers)}
      end)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    Enum.join([preamble() | sources(packages)] ++ blocks, "\n\n") <> "\n"
  end

  defp sort_key(p), do: {@order[p.ecosystem], p.name, p.version}

  defp preamble do
    """
    Third-party notices

    Troupe is licensed under the Apache License, Version 2.0: see LICENSE and NOTICE. It
    is built with the third-party packages below, each under its own licence, and this
    file carries each package's licence as the package ships it: the text of its LICENSE,
    COPYING and NOTICE files. A package that ships none is listed under the standard text
    of the licence it declares, and says so.

    The packages are the ones the repository's lock files name: every Hex package, for the
    daemon, the TUI and the server images, development and test tools included; every Rust
    crate of the desktop app, for every platform; and the npm packages the GUI depends on
    to run, which are what its bundle is made from. That is more than any one download or
    image contains. Not listed, because no lock file names them: the Erlang/OTP runtime
    every Elixir build carries (Apache-2.0, whose text is LICENSE), and the zstd library
    that ezstd compiles into its NIF (BSD-3-Clause OR GPL-2.0-only, used under
    BSD-3-Clause).

    Generated by `elixir scripts/licences.exs` from the lock files. The inventory, with the
    policy every licence is checked against, is docs/third-party-licences.md in Troupe's
    repository: https://github.com/it-minds/troupe\
    """
  end

  # MPL-2.0 asks whoever ships a package in a program to say where its source is. What we
  # ship is the package as its registry publishes it, so that is where.
  defp sources(packages) do
    lines =
      for p <- packages,
          not acceptable?(p.expression),
          Enum.any?(ids(p.expression), &(&1 in @source_offered)),
          uniq: true,
          do: "  #{p.name} #{p.version} (#{p.licence}): #{source(p)}"

    if lines == [] do
      []
    else
      [
        """
        Source code

        These packages are under a licence that asks whoever ships them in a program to say
        where their source code is (MPL-2.0, section 3.2). Troupe uses them unmodified, and
        the source of each is the package exactly as its registry publishes it:

        #{Enum.join(lines, "\n")}\
        """
      ]
    end
  end

  defp source(%{ecosystem: :cargo, name: n, version: v}),
    do: "https://static.crates.io/crates/#{n}/#{n}-#{v}.crate"

  defp source(%{ecosystem: :pnpm, name: n, version: v}),
    do: "https://registry.npmjs.org/#{n}/-/#{Path.basename(n)}-#{v}.tgz"

  defp source(%{ecosystem: :hex, name: n, version: v}),
    do: "https://repo.hex.pm/tarballs/#{n}-#{v}.tar"

  defp block(kind, text, shippers) do
    names =
      shippers
      |> Enum.group_by(& &1.ecosystem)
      |> Enum.sort_by(fn {ecosystem, _} -> @order[ecosystem] end)
      |> Enum.map(fn {ecosystem, ps} ->
        wrap("#{@kinds[ecosystem]}: #{Enum.map_join(ps, ", ", & &1.name)}", "  ")
      end)

    how =
      case kind do
        :shipped ->
          []

        {:standard, id} ->
          [
            wrap(
              "None of these ships a licence file. Each declares #{id}, and this is its standard text.",
              ""
            )
          ]
      end

    Enum.join([@rule | names ++ how] ++ [@thin, "", text], "\n")
  end

  # What a package ships, or, when it ships nothing, the standard text of each licence it
  # declares.
  defp texts(p) do
    case licence_files(p) do
      [] -> for id <- ids(p.expression), do: {{:standard, id}, standard_text(id)}
      files -> for file <- files, do: {:shipped, file |> File.read!() |> clean()}
    end
  end

  defp licence_files(p) do
    declared = if p[:licence_file], do: [p.licence_file], else: []

    p.dir
    |> File.ls!()
    |> Enum.filter(&Regex.match?(@licence_file, &1))
    |> Kernel.++(declared)
    |> Enum.map(&Path.expand(&1, p.dir))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # SPDX's text, kept in `scripts/licence-texts/` for every licence the policy allows or
  # excepts; Apache-2.0's is Troupe's own LICENSE.
  defp standard_text(id) do
    path = if id == "Apache-2.0", do: "LICENSE", else: Path.join(@texts, "#{id}.txt")

    case File.read(Path.join(@root, path)) do
      {:ok, text} ->
        clean(text)

      {:error, _} ->
        fail(
          "#{path} is not there: add SPDX's text for #{id} " <>
            "(https://github.com/spdx/license-list-data/tree/main/text)"
        )
    end
  end

  # As published, less what a diff trips on: a byte-order mark, carriage returns, spaces at
  # the ends of lines, blank lines at either end. A file that is not UTF-8 is Latin-1.
  defp clean(bytes) do
    text = if String.valid?(bytes), do: bytes, else: :unicode.characters_to_binary(bytes, :latin1)

    text
    |> String.trim_leading("\uFEFF")
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim("\n")
  end

  defp squeeze(text), do: text |> String.split() |> Enum.join(" ")

  # To the width of the rules, the lines after the first indented by `indent`.
  defp wrap(text, indent) do
    text
    |> String.split(" ")
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | rest] ->
        if String.length(line) + 1 + String.length(word) <= String.length(@rule),
          do: [line <> " " <> word | rest],
          else: [indent <> word, line | rest]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end

Licences.main(System.argv())
