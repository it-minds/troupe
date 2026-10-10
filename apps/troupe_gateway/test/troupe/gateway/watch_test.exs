defmodule Troupe.Gateway.WatchTest do
  @moduledoc """
  Watch mode over the protocol (Decision 844, D106): `watch.get` says whether a workspace
  is watched, how and by which session, and `observe` may ask; `watch.set` takes the
  session that watches, a second session may not take it, off turns off whichever watches,
  and `watch_changed` follows each change. A pod's session never watches.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Event

  setup do
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "troupe-watch-get-#{unique}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    %{workspace: workspace, state_dir: state_dir}
  end

  defp start(context, opts \\ []) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, steps: [], default: {:text, "done"}},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        [
          workspace: context.workspace,
          fake: fake,
          config_overrides: [
            provider: "fake",
            model: "fake-model",
            state_dir: context.state_dir
          ]
        ] ++ opts
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    _ = :sys.get_state(Troupe.Sessions.Index)
    session
  end

  defp get(root), do: Dispatch.call("watch.get", %{"workspace" => root}, context(:observe))

  defp set(root, enabled, extra \\ %{}) do
    params =
      Map.merge(
        %{
          "workspace" => root,
          "enabled" => enabled,
          "command_id" => "c-#{System.unique_integer([:positive])}"
        },
        extra
      )

    Dispatch.call("watch.set", params, context(:admin))
  end

  test "watch.get says whether the workspace is watched, and watch_changed follows watch.set",
       context do
    session = start(context)
    Troupe.subscribe(session.id)
    root = session.workspace.root_real

    assert {:ok, %{"enabled" => false, "backend" => "off", "session_id" => nil}} = get(root)

    assert {:ok, %{"enabled" => true, "backend" => backend}} =
             set(root, true, %{"session_id" => session.id})

    sid = session.id

    assert_receive {:troupe_event, ^sid,
                    %Event{
                      type: "watch_changed",
                      data: %{"enabled" => true, "backend" => ^backend}
                    }},
                   5_000

    assert {:ok, %{"enabled" => true, "backend" => ^backend, "session_id" => ^sid}} = get(root)

    # Reading it is a status line's business; setting it is not.
    assert {:error, %{message: "forbidden"}} =
             Dispatch.call(
               "watch.set",
               %{"workspace" => root, "enabled" => false, "command_id" => "c-observe"},
               context(:observe)
             )

    assert {:ok, %{"enabled" => false, "backend" => "off"}} = set(root, false)

    assert_receive {:troupe_event, ^sid,
                    %Event{type: "watch_changed", data: %{"enabled" => false, "backend" => "off"}}},
                   5_000

    assert {:ok, %{"enabled" => false, "session_id" => nil}} = get(root)
  end

  test "a second session in the workspace may not take watch from the one that has it",
       context do
    first = start(context)
    second = start(context)
    root = first.workspace.root_real

    assert {:ok, %{"enabled" => true}} = set(root, true, %{"session_id" => first.id})

    assert {:error, %{message: "conflict", data: %{reason: "watch is exclusive per workspace"}}} =
             set(root, true, %{"session_id" => second.id})

    first_id = first.id
    assert {:ok, %{"session_id" => ^first_id}} = get(root)

    # Off, from anyone, turns off the session that watches.
    assert {:ok, %{"enabled" => false}} = set(root, false)
    assert {:ok, %{"enabled" => false}} = get(root)
  end

  test "a pod's session refuses to watch", context do
    session = start(context, kind: :team)
    root = session.workspace.root_real

    assert {:error,
            %{message: "forbidden", data: %{reason: "watch mode runs where the files are"}}} =
             set(root, true, %{"session_id" => session.id})

    assert {:ok, %{"enabled" => false}} = get(root)
  end

  defp context(scope) do
    scopes =
      case scope do
        :observe -> [:observe]
        :admin -> [:observe, :control, :admin]
      end

    %Dispatch.Context{
      principal: %{"subject" => "someone@example.test", "kind" => "user"},
      scopes: scopes,
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end
end
