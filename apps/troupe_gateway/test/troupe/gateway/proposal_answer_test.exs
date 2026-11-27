defmodule Troupe.Gateway.ProposalAnswerTest do
  @moduledoc """
  `session.proposal.answer` (#1208): the owner's `later` or `never` to what the harness
  proposed, recorded once as `proposal_answered`; a collaborator holding `control` is
  refused with a sentence, as `shell.run` refuses one, and a second answer is refused.
  `async: false`, as it installs the host's proposal functions.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Event

  @moduletag timeout: 60_000

  setup do
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "troupe-proposal-answer-#{unique}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    File.write!(Path.join(workspace, "index.html"), "<h1>Numbers</h1>")

    Troupe.Proposals.install(
      fn _sid, _proposal -> {:ok, %{"propose" => true, "mode" => "direct"}} end,
      fn _sid, _kind, _key -> :ok end
    )

    Troupe.Artifacts.install(fn params, _ctx ->
      {:ok,
       %{
         "id" => "art-weekly",
         "version" => 1,
         "title" => params["title"],
         "url" => "https://a.example.test/a/art-weekly/"
       }}
    end)

    on_exit(fn ->
      Troupe.Proposals.uninstall()
      Troupe.Artifacts.uninstall()
      File.rm_rf!(base)
    end)

    %{workspace: workspace, state_dir: state_dir}
  end

  defp proposed(context) do
    steps = [
      {:tools, [{"shell", %{"command" => "curl --version"}}]},
      {:tools,
       [
         {"publish_artifact",
          %{
            "title" => "Numbers",
            "kind" => "html",
            "files" => ["index.html"],
            "visibility" => "private"
          }}
       ]},
      {:text, "Published."}
    ]

    fake = start_supervised!({Troupe.LLM.Fake, steps: steps, default: {:text, "done"}})

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake-model",
          auto_approve: true,
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "make the report")

    assert_receive {:troupe_event, _,
                    %Event{type: "proposal_made", data: %{"id" => "proposal-1"}}},
                   10_000

    session
  end

  defp answer(session, decision, scope, command_id),
    do:
      Dispatch.call(
        "session.proposal.answer",
        %{
          "session_id" => session.id,
          "id" => "proposal-1",
          "decision" => decision,
          "command_id" => command_id
        },
        context(scope)
      )

  test "the owner's later is recorded once, under their name; a second answer is refused",
       context do
    session = proposed(context)

    assert {:ok, %{"accepted" => true, "decision" => "later"}} =
             answer(session, "later", :admin, "c-1")

    assert_receive {:troupe_event, _,
                    %Event{type: "proposal_answered", data: data, actor: actor}},
                   5_000

    assert data == %{"id" => "proposal-1", "decision" => "later"}
    assert actor.subject == "someone@example.test"

    assert {:error,
            %{
              message: "invalid_params",
              data: %{reason: "the proposal proposal-1 was already answered: later"}
            }} =
             answer(session, "never", :admin, "c-2")
  end

  test "a collaborator holding control is refused with a sentence, and nothing is recorded",
       context do
    session = proposed(context)

    assert {:error, error} = answer(session, "never", :control, "c-3")
    assert error.message == "forbidden"
    assert error.data.reason == "only the session's owner answers what the harness proposes"

    assert {:error, %{message: "forbidden", data: %{required_scope: "control"}}} =
             answer(session, "later", :observe, "c-4")

    refute Enum.any?(Troupe.events(session.id), &(&1.type == "proposal_answered"))
  end

  test "a yes is not answered here: it is the plane's", context do
    session = proposed(context)

    assert {:error, %{data: %{reason: "a yes is the plane's" <> _}}} =
             answer(session, "accepted", :admin, "c-5")
  end

  defp context(scope) do
    scopes =
      case scope do
        :observe -> [:observe]
        :control -> [:observe, :control]
        :admin -> [:observe, :control, :admin]
      end

    %Dispatch.Context{
      principal: %{
        "subject" => "someone@example.test",
        "display_name" => "Someone",
        "kind" => "user"
      },
      scopes: scopes,
      connection: self()
    }
  end
end
