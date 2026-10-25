defmodule Troupe.Plane.MemoryBlameTest do
  @moduledoc """
  Who wrote each line of a memory document (#55's provenance): blame, not history. Each
  version's lines are walked against the one before it, so a line keeps who saved the
  version it came in, and an agent's entry names the session and the agent it came from,
  read off the version's audit row. Nothing is kept for it beyond the versions and the
  audit. `admin.memory.get` answers it for the version shown, `me.memory` with `blame` for
  the person's own.

  Against the development OpenBao for the signature, as `UserMemoryTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Harness, Memory}

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    %{
      root: Admin.actor_for(person("root@example.test", ["platform"])),
      other: Admin.actor_for(person("other@example.test", ["platform"])),
      ada: person("ada@example.test", [])
    }
  end

  test "each line of the organisation's names the version it came in and who saved it", context do
    {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "One.\nTwo.", 0)

    {:ok, _} =
      Admin.memory_put(context.other, "organisation", nil, "One.\nTwo, changed.\nThree.", 1)

    assert {:ok, doc} = Admin.memory_get(context.root, "organisation", nil, nil)

    assert [
             %{"text" => "One.", "version" => 1, "by" => "root@example.test", "at" => _},
             %{"text" => "Two, changed.", "version" => 2, "by" => "other@example.test"},
             %{"text" => "Three.", "version" => 2, "by" => "other@example.test"}
           ] = doc.lines

    # The version shown, as it stood then.
    assert {:ok, first} = Admin.memory_get(context.root, "organisation", nil, 1)

    assert [%{"text" => "One.", "version" => 1}, %{"text" => "Two.", "version" => 1}] =
             first.lines

    # A rollback's lines keep who wrote them in the version rolled back to.
    {:ok, _} = Admin.memory_rollback(context.other, "organisation", nil, 1, 2)
    assert {:ok, rolled} = Admin.memory_get(context.root, "organisation", nil, nil)
    assert rolled.version == 3

    assert Enum.map(rolled.lines, &{&1["text"], &1["version"], &1["by"]}) ==
             [{"One.", 1, "root@example.test"}, {"Two.", 1, "root@example.test"}]
  end

  test "me.memory with blame names an agent's entry's session and agent, and the person's own lines as theirs",
       context do
    as = %{user: context.ada, platform_admin?: false}

    {:ok, _} =
      Harness.call("me.memory.put", %{"text" => "I write British English.", "version" => 0}, as)

    {:ok, _} =
      Harness.call(
        "me.memory.put",
        %{
          "append" => "Prefers small pull requests.",
          "session" => "20261025T101112-abc123",
          "agent" => "build"
        },
        as
      )

    assert {:ok, %{"user" => own}} = Harness.call("me.memory", %{"blame" => true}, as)
    assert [mine | rest] = own["lines"]
    assert mine == Map.take(mine, ~w(text version by at)) and mine["by"] == "ada@example.test"

    assert %{
             "text" => "- Prefers small pull requests.",
             "version" => 2,
             "session" => "20261025T101112-abc123",
             "agent" => "build"
           } =
             List.last(rest)

    # Without it, as every poll asks, no lines.
    assert {:ok, %{"user" => plain}} = Harness.call("me.memory", %{}, as)
    refute Map.has_key?(plain, "lines")
  end
end
