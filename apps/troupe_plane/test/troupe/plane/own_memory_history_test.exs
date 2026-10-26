defmodule Troupe.Plane.OwnMemoryHistoryTest do
  @moduledoc """
  A person's own memory as their own app reads its history (#55): every
  version with who saved it and when, any one of them beside any other as the plane's line
  diff, and a rollback to one as the next version, audited as one, its lines keeping who
  wrote them. The person's own alone, as `me.memory` is: nobody else's history is reachable.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Harness, Identity, Memory}

  setup do
    _engineering = team_with_grant("engineering", "dev", name: "engineering")

    %{
      ada: person("ada@example.test", ["engineering"]),
      bo: person("bo@example.test", ["engineering"])
    }
  end

  test "lists every version and sets any two side by side", context do
    {:ok, _} = put(context.ada, %{"text" => "One.", "version" => 0})
    {:ok, _} = put(context.ada, %{"text" => "One.\nTwo.", "version" => 1})
    {:ok, _} = put(context.ada, %{"text" => "Two.\nThree.", "version" => 2})

    assert {:ok, now} = Harness.call("me.memory.history", %{}, as(context.ada))
    assert Enum.map(now["versions"], & &1["version"]) == [3, 2, 1]
    assert hd(now["versions"])["changed_by"] == "ada@example.test"
    assert now["version"] == 3
    assert now["text"] == "Two.\nThree."
    # Beside the one before it where none is named.
    assert now["against"] == 2
    assert now["against_text"] == "One.\nTwo."

    assert {:ok, beside} =
             Harness.call("me.memory.history", %{"version" => 3, "against" => 1}, as(context.ada))

    assert beside["against"] == 1
    assert %{"op" => "del", "text" => "One."} in beside["diff"]
    assert %{"op" => "add", "text" => "Three."} in beside["diff"]

    assert {:error, %{message: "not_found"}} =
             Harness.call("me.memory.history", %{"version" => 9}, as(context.ada))

    # Bo's own has none of Ada's.
    assert {:ok, %{"versions" => [], "version" => nil, "text" => ""}} =
             Harness.call("me.memory.history", %{}, as(context.bo))
  end

  test "rolls back to a version as the next one, audited, its lines keeping who wrote them",
       context do
    {:ok, _} = put(context.ada, %{"text" => "Mine.", "version" => 0})
    {:ok, _} = Memory.append_own(context.ada, "Uses pnpm.", session: "s-1", agent: "agent:build")
    {:ok, _} = put(context.ada, %{"text" => "Gone.", "version" => 2})

    assert {:ok, %{"changed" => true, "user" => %{"version" => 4, "text" => text}}} =
             Harness.call("me.memory.rollback", %{"to" => 2, "version" => 3}, as(context.ada))

    assert text == Memory.version(context.ada, 2).text

    [row | _] = Enum.filter(Audit.list(), &(&1.action == "memory.put"))
    assert row.detail["rolled_back_to"] == 2
    assert row.detail["note"] == "rolled back to v2"
    refute inspect(row.detail) =~ "pnpm"

    entry = Enum.find(Memory.blame(context.ada), &(&1["text"] =~ "Uses pnpm."))
    assert entry["session"] == "s-1"
    assert entry["agent"] == "agent:build"

    # Over a version somebody replaced since: refused, naming the one in force.
    assert {:error, %{message: "conflict", data: %{version: 4}}} =
             Harness.call("me.memory.rollback", %{"to" => 1, "version" => 3}, as(context.ada))

    assert {:error, %{message: "not_found"}} =
             Harness.call("me.memory.rollback", %{"to" => 9, "version" => 4}, as(context.ada))

    assert {:error, %{message: "invalid_params"}} =
             Harness.call("me.memory.rollback", %{"version" => 4}, as(context.ada))

    assert Memory.current(context.ada).version == 4
  end

  test "a service principal has none", _context do
    principal = %Identity.User{subject: "svc:build", kind: "service"}

    for {method, params} <- [
          {"me.memory.history", %{}},
          {"me.memory.rollback", %{"to" => 1, "version" => 1}}
        ] do
      assert {:error, %{message: "forbidden"}} = Harness.call(method, params, as(principal))
    end
  end

  defp put(user, params), do: Harness.call("me.memory.put", params, as(user))

  defp as(user), do: %{user: user, platform_admin?: false}
end
