defmodule Troupe.Plane.ConsoleCoverageTest do
  @moduledoc """
  Every administrative method is reachable from a named screen, or says why not.

  `AdminParityTest` proves the context, the JSON-RPC surface and the MCP tools agree. Nothing
  proved the *console* did, and that is not a hypothetical: `admin.profile.put` was in the
  TypeScript client and on no screen. A capability that exists in the API and nowhere a
  person can click is a capability the product does not really have, and it never happens by
  decision — somebody adds a method, the screen is a separate job, and the separate job does
  not happen.

  This is the test that makes the separate job impossible to skip. It fails on a new method,
  it fails on a screen that stops calling something it claims, and the only way to satisfy it
  without building a screen is to write down a reason somebody will read.
  """

  use ExUnit.Case, async: true

  alias Troupe.Plane.Admin
  alias Troupe.Plane.Admin.{API, Console}

  # The same exemption `AdminParityTest` makes, for the same reason: these work out *who is
  # asking* rather than doing anything on their behalf.
  @not_actions [actor_for: 1, actor_for_session: 1, actor_for_subject: 1, admin?: 1]

  # Screens whose module is not `Live.<Name>`, because the navigation's name and the
  # module's are allowed to differ where the module predates the grouping.
  @modules %{
    fleet: Troupe.Plane.Web.Live.Workers,
    profiles: Troupe.Plane.Web.Live.ProfileEditor
  }

  # The same filter `AdminParityTest` applies, because the two tests are about one list and
  # a stricter copy here would fail about functions that test has already accounted for.
  defp actions do
    Admin.__info__(:functions)
    |> Enum.reject(fn {name, arity} = function ->
      function in @not_actions or name |> Atom.to_string() |> String.starts_with?("_") or
        arity == 0
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  # Every method the API exposes, by the context function it names. The API is the list that
  # matters: a context function nothing exposes is `AdminParityTest`'s business.
  defp exposed do
    API.list() |> Enum.map(& &1.function) |> Enum.uniq()
  end

  defp screen_module(screen) do
    Map.get_lazy(@modules, screen, fn ->
      Module.concat(Troupe.Plane.Web.Live, screen |> Atom.to_string() |> Macro.camelize())
    end)
  end

  # Read from the tree rather than from `module_info(:compile)`, whose path is the machine
  # the release was built on. `File.cwd!` is the app's own directory under `mix cmd`, and
  # the umbrella root otherwise, so both are tried.
  defp source(module) do
    # The whole underscored module path, not its last segment: `Live.Sessions` and the
    # `Plane.Sessions` context share a basename, and matching on that read the context and
    # then reported that the screen never called something it calls on line 40.
    path = Macro.underscore(module) <> ".ex"

    ["lib/#{path}", "apps/troupe_plane/lib/#{path}"]
    |> Enum.filter(&File.regular?/1)
    |> case do
      [found | _] -> File.read!(found)
      [] -> nil
    end
  end

  describe "coverage" do
    test "every method the API exposes is placed on a screen or given a reason" do
      unplaced = Enum.reject(exposed(), &Console.placement(&1))

      assert unplaced == [],
             """
             These administrative methods are reachable from no console screen and have no
             reason recorded:

                 #{Enum.map_join(unplaced, "\n    ", &inspect/1)}

             Add each to `Troupe.Plane.Admin.Console`: `{:screen, :name}` where somebody
             does it, or `{:api_only, "why a person would not click it"}`. A reason is a
             sentence about the operation, not a note that the screen is not built.
             """
    end

    test "nothing is placed that the API does not expose" do
      # A placement for a method nobody can call is a screen claim about nothing, and the
      # likeliest cause is a rename that updated one list and not the other.
      stale = Map.keys(Console.placements()) -- exposed()

      assert stale == [],
             "these placements name methods the API no longer exposes: #{inspect(stale)}"
    end

    test "every context action is exposed, so coverage cannot be satisfied by hiding one" do
      # Belt and braces with `AdminParityTest`: if a function could be dropped from the API
      # to make this file pass, the two tests together would let it through.
      missing = actions() -- exposed()
      assert missing == [], "context functions with no API method: #{inspect(missing)}"
    end
  end

  describe "the screens named" do
    test "all exist, and all are LiveViews" do
      # Every one, collected. A test that stopped at the first missing screen would hand
      # somebody one name at a time across as many runs as there are screens to build.
      missing =
        for screen <- Console.screens(),
            module = screen_module(screen),
            not (Code.ensure_loaded?(module) and function_exported?(module, :mount, 3)),
            not Map.has_key?(Console.unbuilt(), screen),
            do: "#{screen} (#{inspect(module)})"

      assert missing == [],
             """
             The console names these screens, they do not exist as LiveViews, and nothing in
             `Console.owed/0` accounts for them:

                 #{Enum.join(missing, "\n    ")}
             """
    end

    test "and a screen that does not exist yet has nothing placed on it but its own debt" do
      # A screen named in the navigation with placements it cannot possibly keep would pass
      # the check above and fail nobody. Everything placed on an unbuilt screen must be
      # something `owed/0` says is owed *there*.
      premature =
        for screen <- Console.screens(),
            module = screen_module(screen),
            not Code.ensure_loaded?(module),
            function <- Console.reached_by(screen),
            Map.get(Console.owed(), function) != screen,
            do: "#{function} is placed on #{screen}, which does not exist"

      assert premature == [], Enum.join(premature, "\n")
    end

    test "and a screen recorded as unbuilt is in fact not built" do
      # The list can only shrink. Build one and this fails until the entry goes, which is
      # what stops `unbuilt` becoming a place names are left after the work is done.
      built =
        for {screen, _what} <- Console.unbuilt(),
            module = screen_module(screen),
            Code.ensure_loaded?(module),
            function_exported?(module, :mount, 3),
            do: "#{screen} exists now; delete it from Console.unbuilt/0"

      assert built == [], Enum.join(built, "\n")
    end

    test "and every unbuilt screen is one the console actually names" do
      stray = Map.keys(Console.unbuilt()) -- Console.screens()
      assert stray == [], "unbuilt names screens the console does not have: #{inspect(stray)}"
    end

    test "actually call what they are said to reach" do
      # The strong half. A map that said `:teams` for something Teams does not call would be
      # a worse lie than no map at all — it would pass a coverage test while the button did
      # not exist.
      unreached =
        for screen <- Console.screens(),
            module = screen_module(screen),
            text = source(module),
            not is_nil(text),
            function <- Console.reached_by(screen),
            not String.contains?(text, "Admin.#{function}("),
            not Map.has_key?(Console.owed(), function),
            do: "#{function} is placed on #{screen}, which never calls it"

      assert unreached == [],
             """
             These placements are claims the screens do not keep:

                 #{Enum.join(unreached, "\n    ")}

             Either the screen lost the call, or the placement is aspirational — and if it
             is aspirational, it belongs in `Console.owed/0` where it is visible.
             """
    end

    test "and the debt shrinks: nothing owed is already done" do
      # The rule that makes `owed` bookkeeping rather than an excuse. Close a gap and this
      # fails until the entry is deleted, which is the opposite of a list that only grows.
      settled =
        for {function, screen} <- Console.owed(),
            module = screen_module(screen),
            text = source(module),
            not is_nil(text),
            String.contains?(text, "Admin.#{function}("),
            do: "#{function} works on #{screen} now; delete it from Console.owed/0"

      assert settled == [], Enum.join(settled, "\n")
    end

    test "and nothing is owed that the console never claimed" do
      # An entry for something no screen is placed on would be debt against a plan nobody
      # wrote down, which is where a backlog stops meaning anything.
      stray =
        for {function, screen} <- Console.owed(),
            Console.placement(function) != {:screen, screen},
            do: "#{function} is owed on #{screen} but placed elsewhere"

      assert stray == [], Enum.join(stray, "\n")
    end

    test "and every screen that exists can be read, so the check above means something" do
      # A source file this test cannot find would make the check above pass by vacuity,
      # which is the one way a coverage test fails silently.
      unreadable =
        for screen <- Console.screens(),
            module = screen_module(screen),
            Code.ensure_loaded?(module),
            is_nil(source(module)),
            do: "#{screen} (#{inspect(module)})"

      assert unreadable == [], "could not read the source of: #{Enum.join(unreadable, ", ")}"
    end
  end

  describe "the reasons" do
    test "are sentences, and there are few of them" do
      reasons = Console.api_only()

      for {function, reason} <- reasons do
        assert String.length(reason) > 20,
               "the reason for #{inspect(function)} is too short to be one: #{inspect(reason)}"

        refute reason =~ ~r/not (yet )?(built|implemented|done)/i,
               """
               #{inspect(function)} is recorded as API-only because its screen is not built:

                   #{reason}

               That is a backlog item wearing a reason's clothes. Either build the screen or
               say why a person would never click it.
               """
      end

      # A list that grows is the console drifting behind the API again, one justified
      # exception at a time.
      assert length(reasons) <= 3,
             "#{length(reasons)} methods are API-only; the console is drifting behind again"
    end
  end
end
