defmodule Troupe.Gateway.SessionLifespanTest do
  @moduledoc """
  How long a session on this computer lasts (#1209): asked for at `session.create` (absent
  is normal), recorded in `session_created`, kept as a mark beside the log so it outlives the
  session going dormant, answered with `erases_at` in every listing, changed with
  `session.lifespan.set`, which a running session's log says. The daemon's `initialize`
  says `lifespans`. A throwaway session proposes nothing for a team's memory.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Dispatch, Memory}
  alias Troupe.Protocol.Lifespan
  alias Troupe.Tool.Ctx

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-lifespan-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "work")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{workspace: workspace}
  end

  test "a throwaway session is made so, listed with when it goes, and says it while dormant",
       context do
    assert {:ok, %{"session_id" => id, "lifespan" => "throwaway"}} =
             create(context, %{"lifespan" => "throwaway"})

    on_exit(fn -> Troupe.stop_session(id) end)

    assert %{"lifespan" => "throwaway", "erases_at" => at} = row(id)
    assert {:ok, _at, _offset} = DateTime.from_iso8601(at)

    created = id |> Troupe.events() |> Enum.find(&(&1.type == "session_created"))
    assert created.data["lifespan"] == "throwaway"

    :ok = Troupe.stop_session(id)
    assert %{"state" => "dormant", "lifespan" => "throwaway"} = listed(id)

    assert {:ok, %{"sessions" => [%{"id" => ^id}]}} =
             Dispatch.call(
               "session.list",
               %{"filter" => %{"lifespan" => "throwaway"}},
               context(:observe)
             )
  end

  test "a normal session says so and goes nowhere", context do
    assert {:ok, %{"session_id" => id, "lifespan" => "normal"}} = create(context, %{})
    on_exit(fn -> Troupe.stop_session(id) end)
    assert %{"lifespan" => "normal", "erases_at" => nil} = row(id)
  end

  test "another word is refused, naming the field, before any session exists", context do
    before = length(sessions())

    assert {:error, %{message: "invalid_params", data: %{field: "lifespan"}}} =
             create(context, %{"lifespan" => "kept"})

    assert length(sessions()) == before
  end

  test "session.lifespan.set changes it, running or dormant; a running log says so", context do
    assert {:ok, %{"session_id" => id}} = create(context, %{"lifespan" => "throwaway"})
    on_exit(fn -> Troupe.stop_session(id) end)

    assert {:ok, %{"lifespan" => "persistent", "erases_at" => nil}} = relive(id, "persistent")
    assert row(id)["lifespan"] == "persistent"

    assert [changed] = id |> Troupe.events() |> Enum.filter(&(&1.type == "session_lifespan_changed"))
    assert changed.data == %{"from" => "throwaway", "to" => "persistent", "actor" => "someone@example.test"}

    :ok = Troupe.stop_session(id)
    assert {:ok, %{"lifespan" => "normal"}} = relive(id, "normal")
    assert listed(id)["lifespan"] == "normal"

    assert {:error, %{message: "invalid_params", data: %{field: "lifespan"}}} = relive(id, "forever")
    assert {:error, %{message: "not_found"}} = relive("20200101T000000-Nowher", "normal")
  end

  test "a throwaway session proposes nothing for a team's memory, in words its agent relays",
       context do
    assert {:ok, %{"session_id" => id}} = create(context, %{"lifespan" => "throwaway"})
    on_exit(fn -> Troupe.stop_session(id) end)

    ctx = %Ctx{session_id: id, agent_path: ["root"], workspace: nil, call_id: "c-1", agent_pid: self()}
    assert {:error, said} = Memory.propose("Use the staging cluster", ctx, "team", %{})
    assert said == Lifespan.no_proposals()
  end

  defp create(context, extra) do
    Dispatch.call(
      "session.create",
      Map.merge(
        %{
          "command_id" => "c-#{System.unique_integer([:positive])}",
          "workspace" => context.workspace,
          "worktree" => "never"
        },
        extra
      ),
      context(:admin)
    )
  end

  defp relive(id, lifespan) do
    Dispatch.call(
      "session.lifespan.set",
      %{"command_id" => "l-#{System.unique_integer([:positive])}", "session_id" => id, "lifespan" => lifespan},
      context(:admin)
    )
  end

  defp row(id) do
    {:ok, row} = Dispatch.call("session.get", %{"session_id" => id}, context(:observe))
    row
  end

  defp sessions do
    {:ok, %{"sessions" => sessions}} = Dispatch.call("session.list", %{}, context(:observe))
    sessions
  end

  defp listed(id), do: Enum.find(sessions(), &(&1["id"] == id))

  defp context(scope) do
    scopes =
      case scope do
        :observe -> [:observe]
        :admin -> [:observe, :control, :admin]
      end

    %Dispatch.Context{
      principal: %{
        "subject" => "someone@example.test",
        "display_name" => "Someone",
        "kind" => "user"
      },
      scopes: scopes,
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end
end
