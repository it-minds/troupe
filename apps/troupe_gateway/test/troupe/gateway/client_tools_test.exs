defmodule Troupe.Gateway.ClientToolsTest do
  @moduledoc """
  Stage 4, done items 3 and 4: tools that run on somebody's laptop.

  Three properties, and each one is a thing that would be quietly wrong if it were
  merely intended rather than tested.

  **Consent is a round trip.** A registration with no consent is refused and comes back
  with the challenge to show. Only a registration carrying what the person confirmed is
  accepted. A boolean the client sets on the user's behalf is not consent.

  **The registering connection owns the tool.** `tool.invoke` goes to that connection and
  no other, so a second client attached to the same session cannot invoke a tool it did
  not register, and a registrant that disconnects takes its tools with it — leaving the
  agent with an error result rather than a hung turn.

  **The taint is visible.** A tool running outside the pod is something every other
  participant is entitled to know about, so it is durable and in their summary.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.Protocol.Error
  alias Troupe.Session.{ClientTools, Log}

  @ada "ada@example.test"
  @bob "bob@example.test"

  @tool %{
    "name" => "notes.search",
    "description" => "Search my local notes.",
    "schema" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
  }

  describe "a platform that takes no client-hosted tools" do
    test "refuses the registration with a reason the model can relay", context do
      %{session: session} =
        start_session(context,
          default: {:text, "ok"},
          config: [auto_approve: true, managed_mcp_servers_only: true]
        )

      ada = attach(context, @ada)

      assert {:error, %Error{} = error} =
               Client.call(ada, "tools.register", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id,
                 "tools" => [@tool],
                 "consent" => %{"granted" => true}
               })

      # Not a transport failure and not a consent challenge: the person asked for their
      # notes tool and the answer is a sentence about this platform, which is something
      # the model can pass on and they can act on.
      assert error.message == "forbidden"
      assert error.data["setting"] == "managed_mcp_servers_only"
      assert error.data["reason"] =~ "client-hosted"

      # And nothing was registered, logged or tainted on the way past. A refusal that
      # left a taint behind would say this session had run somebody's laptop code.
      assert ClientTools.list(session.id) == []
      assert ClientTools.taint(session.id) == []

      types = session.id |> Troupe.replay_from(0) |> Enum.map(& &1.type)
      refute "tools_registered" in types
      refute "session_tainted" in types
    end

    test "does not even offer a challenge, so nobody is asked to approve it", context do
      %{session: session} =
        start_session(context,
          default: {:text, "ok"},
          config: [auto_approve: true, managed_mcp_servers_only: true]
        )

      ada = attach(context, @ada)

      # Without the switch this is the call that answers `consent_required` with a
      # challenge to show the person. Asking somebody to approve a thing that will be
      # refused anyway is worse than refusing it.
      assert {:error, %Error{message: "forbidden"}} =
               Client.call(ada, "tools.register", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id,
                 "tools" => [@tool]
               })
    end
  end

  describe "consent" do
    test "a registration without consent is rejected, and says what to show", context do
      %{session: session} = start_session(context, default: {:text, "ok"})
      ada = attach(context, @ada)

      assert {:error, %Error{} = error} =
               Client.call(ada, "tools.register", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id,
                 "tools" => [@tool]
               })

      assert error.message == "consent_required"
      assert is_binary(error.data["challenge"])
      assert error.data["tools"] == ["notes.search"]
      assert is_binary(error.data["prompt"])

      # And nothing was registered on the way past.
      assert ClientTools.list(session.id) == []
    end

    test "a made-up challenge is not consent", context do
      %{session: session} = start_session(context, default: {:text, "ok"})
      ada = attach(context, @ada)

      assert {:error, %Error{message: "consent_required"}} =
               register(ada, session.id, consent: %{"challenge" => "i-made-this-up"})
    end

    test "another client's challenge is not this client's consent", context do
      %{session: session} = start_session(context, default: {:text, "ok"})
      ada = attach(context, @ada)
      bob = attach(context, @bob)

      challenge = challenge_for(ada, session.id)

      assert {:error, %Error{message: "consent_required"}} =
               register(bob, session.id, consent: %{"challenge" => challenge})
    end

    test "registering needs control, not merely a seat", context do
      %{session: session} = start_session(context, default: {:text, "ok"})
      watcher = attach(context, @bob <> "#observe")

      assert {:error, %Error{message: "forbidden"}} = register(watcher, session.id)
    end
  end

  describe "a registered tool" do
    test "is served by the client that registered it, logged, and taints the session",
         context do
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"client.notes.search", %{"q" => "the thing"}}]}],
          default: {:text, "found it"}
        )

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", level: :summary)

      assert {:ok, result} = register(ada, session.id)
      assert result["registered"] == ["client.notes.search"]
      assert result["taint"] == "personal_connector"

      # B's *summary* shows the taint, which is the done item's own wording: a
      # participant who is not watching the detail stream still finds out.
      assert_receive {:troupe_event, _t, _i, %Event{type: "summary_diff"} = diff}, 10_000
      taint = diff.data["changed"]["taint"]
      assert is_list(taint)
      assert [%{"kind" => "personal_connector", "actor" => @ada} | _] = taint
      assert hd(taint)["tools"] == ["client.notes.search"]

      {:ok, _} = Client.subscribe(ada, "session:#{session.id}", from_seq: 0)
      {:ok, _} = input(ada, session.id, "search my notes", Client.command_id())

      # The agent's call arrives at A, over A's own connection, as a request A answers.
      assert_receive {:troupe_request, id, "tool.invoke", params}, 15_000
      assert params["name"] == "client.notes.search"
      assert params["arguments"] == %{"q" => "the thing"}
      assert is_binary(params["call_id"])

      :ok = Client.respond(ada, id, %{"content" => "three notes about the thing"})

      events = collect("session:#{session.id}", &(&1.type == "tool_call_completed"))

      completed = Enum.find(events, &(&1.type == "tool_call_completed"))
      assert completed.data["name"] == "client.notes.search"
      assert completed.data["ok"] == true
      assert completed.data["content"] =~ "three notes"

      # Durable, so a replay tells the same story.
      types = session.id |> Log.replay() |> Enum.map(& &1.type)
      assert "tools_registered" in types
      assert "session_tainted" in types
    end

    test "is invoked on its registrant's connection and on no other", context do
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"client.notes.search", %{"q" => "the thing"}}]}],
          default: {:text, "found it"}
        )

      ada = attach(context, @ada)

      # B's events go to a process of their own, so "B was never asked" is a claim about
      # B's own mailbox rather than about a mailbox A and B share.
      elsewhere = mailbox()
      bob = attach(context, @bob, owner: elsewhere)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)

      {:ok, _} = register(ada, session.id)

      # B holds no registration, so B has nothing to unregister and nothing to serve.
      assert {:ok, %{"unregistered" => []}} =
               Client.call(bob, "tools.unregister", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id,
                 "tools" => ["client.notes.search"]
               })

      assert [%{name: "client.notes.search"}] = ClientTools.list(session.id)

      {:ok, _} = input(ada, session.id, "search my notes", Client.command_id())

      assert_receive {:troupe_request, id, "tool.invoke", _params}, 15_000
      :ok = Client.respond(ada, id, %{"content" => "three notes"})

      # And B, attached to the same session with the same scopes, was never asked.
      refute Enum.any?(delivered(elsewhere), &match?({:troupe_request, _, "tool.invoke", _}, &1))
    end

    test "goes through the same permission map as a built-in", context do
      # A denied tool is never run, exactly as for `shell`: the list sent to the model is
      # a convenience, and the gate is in the harness.
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"client.notes.search", %{"q" => "x"}}]}],
          default: {:text, "ok"}
        )

      ada = attach(context, @ada)
      {:ok, _} = Client.subscribe(ada, "session:#{session.id}", from_seq: 0)

      {:ok, _} =
        register(ada, session.id, tool: Map.put(@tool, "permission", "deny"))

      {:ok, _} = input(ada, session.id, "try it", Client.command_id())

      events = collect("session:#{session.id}", &(&1.type == "tool_call_completed"))
      completed = Enum.find(events, &(&1.type == "tool_call_completed"))

      assert completed, "the model's call produced no result at all"
      assert completed.data["ok"] == false
      assert completed.data["content"] =~ "denied"
      refute_received {:troupe_request, _id, "tool.invoke", _params}
    end
  end

  describe "a registrant that goes away mid-call" do
    test "the agent gets an error result inside the timeout and keeps running", context do
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"client.notes.search", %{"q" => "the thing"}}]}],
          default: {:text, "carried on without it"}
        )

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)

      {:ok, _} = register(ada, session.id)
      {:ok, _} = input(ada, session.id, "search my notes", Client.command_id())

      assert_receive {:troupe_request, _id, "tool.invoke", _params}, 15_000

      # A disappears without answering. The tool timeout is minutes; this must not wait
      # for it, because a dropped connection is knowable immediately.
      started = System.monotonic_time(:millisecond)
      Client.close(ada)

      # Collected in two phases: the first `llm_response` is the turn that *made* the
      # call and is already in the replay, so stopping there would prove nothing.
      events = collect("session:#{session.id}", &(&1.type == "tool_call_completed"), 20_000)
      elapsed = System.monotonic_time(:millisecond) - started
      # Phase one consumed the stream up to the failed call, so the next `llm_response`
      # is the turn the agent carried on with.
      events = events ++ collect("session:#{session.id}", &(&1.type == "llm_response"), 20_000)

      completed = Enum.find(events, &(&1.type == "tool_call_completed"))
      assert completed, "the agent never got a result for the call it was waiting on"
      assert completed.data["ok"] == false
      assert completed.data["content"] =~ "disconnected"

      assert elapsed < 10_000,
             "took #{elapsed}ms to notice a dropped registrant; that is a hung turn"

      # And the turn continued: the model got the failure and answered.
      assert length(Enum.filter(events, &(&1.type == "llm_response"))) >= 2,
             "the agent stopped after the failed call instead of carrying on"

      unregistered = Enum.find(events, &(&1.type == "tools_unregistered"))
      assert unregistered, "a dropped registrant must log tools_unregistered"
      assert unregistered.data["tools"] == ["client.notes.search"]
      assert unregistered.data["reason"] == "disconnected"

      # B cannot invoke A's tool, because there is no longer any such tool.
      assert ClientTools.list(session.id) == []
      assert ClientTools.owner(session.id, "client.notes.search") == :error
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp register(client, session_id, opts \\ []) do
    tool = Keyword.get(opts, :tool, @tool)

    consent =
      Keyword.get_lazy(opts, :consent, fn ->
        %{"challenge" => challenge_for(client, session_id), "confirmed_by" => "the person"}
      end)

    Client.call(client, "tools.register", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "tools" => [tool],
      "consent" => consent
    })
  end

  # A process that does nothing but accumulate what it is sent, so that "B was never
  # asked" can be asked of B alone.
  defp mailbox do
    test = self()

    pid =
      spawn_link(fn ->
        send(test, {:ready, self()})
        keep([])
      end)

    receive do
      {:ready, ^pid} -> pid
    after
      5_000 -> flunk("mailbox never started")
    end
  end

  defp keep(acc) do
    receive do
      {:delivered, from, reference} ->
        send(from, {:delivered, reference, Enum.reverse(acc)})
        keep(acc)

      message ->
        keep([message | acc])
    end
  end

  defp delivered(mailbox) do
    reference = make_ref()
    send(mailbox, {:delivered, self(), reference})

    receive do
      {:delivered, ^reference, messages} -> messages
    after
      5_000 -> flunk("mailbox did not answer")
    end
  end

  # The challenge the worker issues when asked without consent. A harness shows this to
  # the user and sends back what they confirmed; a test does the same thing without the
  # person.
  defp challenge_for(client, session_id) do
    {:error, %Error{data: data}} =
      Client.call(client, "tools.register", %{
        "command_id" => Client.command_id(),
        "session_id" => session_id,
        "tools" => [@tool]
      })

    data["challenge"]
  end

  defp input(client, session_id, text, command_id) do
    Client.call(client, "input.send", %{
      "command_id" => command_id,
      "session_id" => session_id,
      "text" => text
    })
  end
end
