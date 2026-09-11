defmodule Troupe.Plane.AdminParityTest do
  @moduledoc """
  Three surfaces, one context, and a test that keeps it that way.

  The panel, the admin JSON-RPC and `troupe admin` are supposed to be three renderings of
  `Troupe.Plane.Admin`. Left to care alone that lasts about a release: somebody adds a
  button, the CLI does not get it, and an operator who works over SSH finds out months
  later that the thing they need is only in a browser.

  So it is enumerated. Every public function of the context must have a method and a
  command; every method and command must name a function that exists; and the panel must
  call nothing else.
  """

  use ExUnit.Case, async: true

  alias Troupe.Ctl.Admin, as: CLI
  alias Troupe.Plane.Admin
  alias Troupe.Plane.Admin.API

  # Not administrative actions: `actor_for/1` works out who is asking and `admin?/1`
  # answers a question about them. Listed rather than filtered by a naming rule, because
  # a rule would silently exempt whatever a future name happened to match.
  @not_actions [actor_for: 1, admin?: 1]

  describe "every action has three surfaces" do
    test "each context function has an admin API method" do
      covered = API.methods() |> Map.values() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      missing = MapSet.difference(MapSet.new(action_names()), covered)

      assert MapSet.size(missing) == 0, """
      These are in Troupe.Plane.Admin with no admin API method:

        #{Enum.join(MapSet.to_list(missing), "\n  ")}

      Add them to Troupe.Plane.Admin.API, or the panel will be able to do something no
      other client can.
      """
    end

    test "each context function has a `troupe admin` command" do
      by_method = Map.new(API.methods(), fn {method, {function, _args}} -> {method, function} end)
      covered = CLI.methods() |> Enum.map(&Map.fetch!(by_method, &1)) |> MapSet.new()
      missing = MapSet.difference(MapSet.new(action_names()), covered)

      assert MapSet.size(missing) == 0, """
      These are in Troupe.Plane.Admin with no `troupe admin` command:

        #{Enum.join(MapSet.to_list(missing), "\n  ")}

      Add them to Troupe.Ctl.Admin, or an operator who works over SSH cannot do what
      somebody with a browser can.
      """
    end

    test "no method names a function the context does not have" do
      actions = MapSet.new(action_names())

      for {method, {function, arguments}} <- API.methods() do
        assert MapSet.member?(actions, function),
               "#{method} names Admin.#{function}/#{length(arguments) + 1}, which does not exist"

        assert function_exported?(Admin, function, length(arguments) + 1),
               "#{method} passes #{length(arguments)} argument(s) to Admin.#{function}, which takes a different number"
      end
    end

    test "no command names a method the API does not have" do
      methods = MapSet.new(Map.keys(API.methods()))

      for method <- CLI.methods() do
        assert MapSet.member?(methods, method), "`troupe admin` has a command for #{method}, which is not a method"
      end
    end
  end

  describe "what the context will not do" do
    test "nothing returns session content" do
      # A function whose name suggests it reads a session's events would be one that
      # could be made to. There is no such function, and this is what keeps it that way.
      forbidden = ~w(events replay log content read subscribe)

      for {name, _arity} <- action_names_with_arity(),
          word <- forbidden do
        refute String.contains?(Atom.to_string(name), word),
               """
               Troupe.Plane.Admin.#{name} looks like it reads session content.

               No admin role grants access to what a session said; reading it requires
               being on the session's ACL. If this function is innocent, it needs a name
               that says so.
               """
      end
    end

    test "membership has no setter" do
      for {name, _arity} <- action_names_with_arity() do
        refute Atom.to_string(name) =~ ~r/member/,
               """
               Troupe.Plane.Admin.#{name} looks like it edits membership.

               Membership comes from the identity provider. A way to change it here would
               be a second source of truth for who is in a team.
               """
      end
    end
  end

  defp action_names, do: Enum.map(action_names_with_arity(), &elem(&1, 0))

  defp action_names_with_arity do
    Admin.__info__(:functions)
    |> Enum.reject(fn {name, arity} = function ->
      function in @not_actions or name |> Atom.to_string() |> String.starts_with?("_") or arity == 0
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end
end
