defmodule Troupe.Gateway.SessionTitleTest do
  @moduledoc """
  A local session's title: given at `session.create`, changed with `session.title.set`,
  kept beside its log so it outlives the session going dormant, and answered in every
  listing. Trimmed, at most 200 bytes, refused past that before the session exists.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-title-#{System.unique_integer([:positive])}")
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

  test "a title given at create is listed, renamed, kept while dormant and taken off", context do
    assert {:ok, %{"session_id" => id, "title" => "Rewrite the loop"}} =
             create(context, %{"title" => "  Rewrite the loop  "})

    on_exit(fn -> Troupe.stop_session(id) end)

    assert row(id)["title"] == "Rewrite the loop"
    assert listed(id)["title"] == "Rewrite the loop"

    assert {:ok, %{"title" => "Plan the port"}} = retitle(id, "Plan the port")
    assert row(id)["title"] == "Plan the port"

    :ok = Troupe.stop_session(id)
    assert listed(id)["state"] == "dormant"
    assert listed(id)["title"] == "Plan the port"

    # Renamed while dormant, and the name is there when it is listed from its log.
    assert {:ok, %{"title" => "Asleep"}} = retitle(id, "Asleep")
    assert listed(id)["title"] == "Asleep"

    assert {:ok, %{"title" => nil}} = retitle(id, "   ")
    assert listed(id)["title"] == nil
  end

  test "a session made without one has none", context do
    assert {:ok, %{"session_id" => id, "title" => nil}} = create(context, %{})
    on_exit(fn -> Troupe.stop_session(id) end)
    assert row(id)["title"] == nil
  end

  test "a title past 200 bytes is refused, naming the field, before any session exists",
       context do
    before = length(sessions())

    assert {:error, %{message: "invalid_params", data: %{field: "title"}}} =
             create(context, %{"title" => String.duplicate("é", 101)})

    assert length(sessions()) == before

    assert {:ok, %{"session_id" => id}} = create(context, %{})
    on_exit(fn -> Troupe.stop_session(id) end)

    assert {:error, %{message: "invalid_params", data: %{field: "title"}}} =
             retitle(id, String.duplicate("a", 201))
  end

  test "a session that is nowhere cannot be renamed", _context do
    assert {:error, %{message: "not_found"}} = retitle("20200101T000000-Nowher", "x")
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

  defp retitle(id, title) do
    Dispatch.call(
      "session.title.set",
      %{
        "command_id" => "t-#{System.unique_integer([:positive])}",
        "session_id" => id,
        "title" => title
      },
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
