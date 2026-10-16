defmodule Troupe.Plane.ConsoleCoverageTest do
  @moduledoc """
  Every administrative method is reachable from an area of the console, or says why not.

  `AdminParityTest` proves the context, the JSON-RPC surface and the MCP tools agree. Nothing
  proved the *console* did, and that is not a hypothetical: `admin.profile.put` was in the
  TypeScript client and on no screen. A capability that exists in the API and nowhere a
  person can click is a capability the product does not really have, and it never happens by
  decision — somebody adds a method, the screen is a separate job, and the separate job does
  not happen.

  This is the test that makes the separate job impossible to skip. It fails on a new method,
  and the only way to satisfy it without placing the method on an area of the console is to
  write down a reason somebody will read. The console's own `test/coverage.test.ts` holds the
  console to each placement: it calls the method, or owes it on that area.
  """

  use ExUnit.Case, async: true

  alias Troupe.Plane.Admin
  alias Troupe.Plane.Admin.{API, Console}
  alias Troupe.Plane.Connections

  # The same exemption `AdminParityTest` makes, for the same reason: these work out *who is
  # asking* rather than doing anything on their behalf.
  @not_actions [actor_for: 1, actor_for_session: 1, actor_for_subject: 1, admin?: 1]

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

  describe "coverage" do
    test "every method the API exposes is placed on an area or given a reason" do
      unplaced = Enum.reject(exposed(), &Console.placement(&1))

      assert unplaced == [],
             """
             These administrative methods are reachable from no console area and have no
             reason recorded:

                 #{Enum.map_join(unplaced, "\n    ", &inspect/1)}

             Add each to `Troupe.Plane.Admin.Console`: `{:area, :name}` where somebody
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

  describe "the areas named" do
    test "are the console's map, and every placement is on one of them" do
      # Whether the console keeps each placement is the console's own coverage test's to
      # say: it reads this table, calls what it reaches, and owes the rest on the same area.
      # What is checked here is that a placement names a place the map has at all.
      off_map =
        for {function, {:area, area}} <- Console.placements(),
            area not in Console.areas(),
            do: "#{function} is placed on #{area}, which is not an area of the console's map"

      assert off_map == [], Enum.join(off_map, "\n")

      assert Console.areas() == Enum.flat_map(Console.groups(), &elem(&1, 1))
      assert Console.areas() == Enum.uniq(Console.areas())
    end

    test "and a placement is an area or a reason, nothing else" do
      odd =
        for {function, placement} <- Console.placements(),
            not match?({:area, area} when is_atom(area), placement),
            not match?({:api_only, reason} when is_binary(reason), placement),
            do: "#{function}: #{inspect(placement)}"

      assert odd == [], Enum.join(odd, "\n")
    end
  end
  describe "what no surface offers" do
    # Done item 9's second half. The mechanism is already proven against a real OpenBao in
    # `Troupe.Plane.PersonCredentialsTest` — the plane's own credential cannot read a slot
    # even knowing exactly where it is. This is the other end of the same claim: there is
    # no *method* to attempt it with, so the refusal cannot be lost by somebody adding one.
    test "a method that reads or removes somebody's credential" do
      offered =
        for method <- API.list(),
            name = to_string(method.name),
            String.contains?(name, "connection") or String.contains?(name, "credential"),
            method.risk != :read or
              Regex.match?(~r/\b(value|secret|reveal|read the credential)\b/i, method.summary),
            do: name

      assert offered == [],
             """
             These methods offer something on a personal credential beyond whether a slot
             is filled:

                 #{Enum.join(offered, "\n    ")}

             The plane holds no credential and no token that could read one. A method here
             would be a claim it does.
             """
    end

    test "and `Troupe.Plane.Connections` exports nothing that returns a value" do
      # Named exactly rather than checked by shape: the module's whole surface is four
      # functions, and this fails when a fifth appears rather than when one misbehaves.
      exported =
        Connections.__info__(:functions)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.sort()

      assert exported == [:assertion, :connected?, :grant, :known_slot],
             """
             `Troupe.Plane.Connections` exports #{inspect(exported)}.

             It is allowed to answer whether a slot is filled and to mint an assertion the
             caller spends itself. Anything else is the plane holding, or being able to
             fetch, somebody's credential.
             """
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
