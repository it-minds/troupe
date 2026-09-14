defmodule Troupe.Plane.AdminParityTest do
  @moduledoc """
  Three surfaces, one context, and a test that keeps it that way.

  The panel, the admin JSON-RPC and the admin MCP server are supposed to be three
  renderings of `Troupe.Plane.Admin`. Left to care alone that lasts about a release:
  somebody adds a button, the JSON-RPC method never appears, and a client that is not a
  browser finds out months later that the thing it needs is only in one.

  So it is enumerated. Every public function of the context must have a method and a tool;
  every method must name a function that exists; and the panel must call nothing else.

  The MCP half checks something the other three do not need: that every method carries the
  prose and the types a caller with no documentation depends on. A model has the tool
  description and nothing else, so an argument with no description is a defect in the
  interface rather than in its documentation.
  """

  use ExUnit.Case, async: true

  alias Troupe.Plane.Admin
  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Admin.API.Method
  alias Troupe.Plane.Admin.MCP

  # Not administrative actions: these work out *who is asking* rather than doing anything
  # on their behalf. Listed one by one rather than filtered by a naming rule, because a
  # rule would silently exempt whatever a future name happened to match.
  @not_actions [actor_for: 1, actor_for_session: 1, actor_for_subject: 1, admin?: 1]

  describe "every action has three surfaces" do
    test "each context function has an admin API method" do
      covered = API.methods() |> Map.values() |> Enum.map(& &1.function) |> MapSet.new()
      missing = MapSet.difference(MapSet.new(action_names()), covered)

      assert MapSet.size(missing) == 0, """
      These are in Troupe.Plane.Admin with no admin API method:

        #{Enum.join(MapSet.to_list(missing), "\n  ")}

      Add them to Troupe.Plane.Admin.API, or the panel will be able to do something no
      other client can.
      """
    end

    test "no method names a function the context does not have" do
      actions = MapSet.new(action_names())

      for {method, %Method{} = declared} <- API.methods() do
        arity = length(declared.arguments) + 1

        assert MapSet.member?(actions, declared.function),
               "#{method} names Admin.#{declared.function}/#{arity}, which does not exist"

        assert function_exported?(Admin, declared.function, arity),
               "#{method} passes #{length(declared.arguments)} argument(s) to Admin.#{declared.function}, which takes a different number"
      end
    end
  end

  describe "the MCP surface" do
    test "every method is a tool, and every tool is a method" do
      tools = MapSet.new(MCP.tools(), & &1["name"])
      methods = MapSet.new(Map.keys(API.methods()), &MCP.tool_name/1)

      assert MapSet.equal?(tools, methods), """
      The MCP tool list and the admin methods have come apart:

        only tools:   #{inspect(MapSet.to_list(MapSet.difference(tools, methods)))}
        only methods: #{inspect(MapSet.to_list(MapSet.difference(methods, tools)))}
      """
    end

    test "a tool name maps back to the method it came from" do
      for {name, _declared} <- API.methods() do
        assert MCP.method_for(MCP.tool_name(name)) == name,
               "#{name} does not survive the round trip through an MCP tool name"
      end
    end

    test "every method says what it does, and every argument says what it is" do
      for {name, %Method{} = declared} <- API.methods() do
        refute declared.summary in [nil, ""], "#{name} has no summary"

        assert String.ends_with?(declared.summary, "."),
               "#{name}'s summary is not a sentence; it is read aloud by a model"

        for argument <- declared.arguments do
          refute argument.description in [nil, ""],
                 "#{name}'s #{argument.name} has no description"

          for property <- argument.properties || [] do
            refute property.description in [nil, ""],
                   "#{name}'s #{argument.name}.#{property.name} has no description"
          end
        end
      end
    end

    test "a destructive method names an argument to confirm, and it exists" do
      for {name, %Method{risk: :destructive} = declared} <- API.methods() do
        assert declared.confirm,
               "#{name} is destructive but names nothing to confirm; there would be no guard on it"

        assert declared.confirm in Method.argument_names(declared),
               "#{name} asks to confirm #{declared.confirm}, which is not one of its arguments"
      end
    end

    test "a schema refuses a field the method does not have" do
      # The failure this prevents: `budget` where the field is `budget_micros`, accepted,
      # changing nothing, and reported as a success.
      schema = Enum.find(MCP.tools(), &(&1["name"] == "admin_team_update"))["inputSchema"]

      assert schema["additionalProperties"] == false
      assert "name" in schema["required"]
      assert schema["properties"]["attrs"]["properties"]["budget_micros"]
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
      function in @not_actions or name |> Atom.to_string() |> String.starts_with?("_") or
        arity == 0
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end
end
