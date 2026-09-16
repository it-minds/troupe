defmodule Troupe.Plane.TriggerNotifyTest do
  @moduledoc """
  The notification half, and the request it must never make.

  A trigger may name a URL the plane posts to when a run ends. That is a request made
  from inside the deployment, with the plane's own network position, at a target
  somebody with `admin.trigger.put` chose — the shape of every server-side request
  forgery there has been. LangGraph shipped a 2026 advisory for the absence of exactly
  this check: a relative webhook target was resolved against the server's own base URL
  and reached an in-process route with no authentication.

  The tests are mostly negative, which is the point: what matters is not that a
  notification arrives but that a target which should not be reachable is not reached,
  and that it is refused at both ends — when it is saved, and again when it is sent,
  because a name is not an address and can stop meaning what it meant.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Triggers
  alias Troupe.Plane.Triggers.Notify

  defmodule Listener do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(test), do: test

    @impl Plug
    def call(conn, test) do
      send(test, {:notified, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "")
    end
  end

  @moduletag timeout: 60_000

  setup do
    team = team_with_grant("engineering", "dev", name: "engineering")
    ada = person("ada@example.test", ["engineering"])

    {:ok, principal, _secret} =
      principal!(team, %{name: "nightly", profiles: ["dev"], sponsor: ada.subject})

    # Everything the deployment allows, so that a refusal in these tests is a refusal
    # about the *target* rather than a policy that happened to say no to everything.
    Application.put_env(:troupe_plane, :egress_allowed, fn _host -> true end)
    on_exit(fn -> Application.delete_env(:troupe_plane, :egress_allowed) end)

    %{team: team, principal: principal}
  end

  describe "a target the plane will not take" do
    test "is refused at save, and the trigger keeps the one it had", context do
      {:ok, _} = put(context, %{"notify_url" => "https://hooks.example.test/runs"})

      refused = [
        # The advisory's case, written four ways. None of these names a host, so each
        # would be resolved against whatever base the sender happened to hold — which,
        # inside the plane, is the plane.
        "/rpc",
        "/trigger/00000000-0000-0000-0000-000000000000",
        "rpc",
        "//example.test/rpc",
        # The same attack spelled out in full.
        "http://127.0.0.1:4000/rpc",
        "http://localhost:4000/rpc",
        "http://[::1]:4000/rpc",
        "http://127.2.3.4/x",
        # Where credentials live on every cloud there is.
        "http://169.254.169.254/latest/meta-data/",
        # A v4 loopback wearing a v6 hat, which is the one a check written for the
        # eight-tuple alone lets through.
        "http://[::ffff:127.0.0.1]/x",
        "http://0.0.0.0/x",
        # Not a scheme the plane speaks, and one that would read a file.
        "file:///etc/passwd",
        "ftp://example.test/x",
        "gopher://example.test/x"
      ]

      for url <- refused do
        assert {:error, error} = put(context, %{"notify_url" => url})
        assert error.message == "invalid_params", "#{url} was not refused"
      end

      # And the one that was there is still there: a refused save changes nothing.
      assert Triggers.get(context.team, "triage").notify_url ==
               "https://hooks.example.test/runs"
    end

    test "is refused again at send, because a name is not an address", _context do
      # `localhost.` and its friends resolve to loopback. The first check looks at what
      # the URL *says*; this one looks at what the name answers — a host that was fine
      # when it was saved and answers 127.0.0.1 today is a DNS rebind, and only the
      # second check sees it.
      assert {:error, reason} = Notify.allowed?("http://localhost/x")
      assert reason =~ "loopback"

      # A name nobody can resolve is refused rather than attempted.
      assert {:error, reason} =
               Notify.allowed?("https://nothing-answers-to-this.invalid/x")

      assert reason =~ "resolves"
    end

    test "is refused when the deployment's egress policy says so", context do
      Application.put_env(:troupe_plane, :egress_allowed, fn host ->
        host == "hooks.example.test"
      end)

      assert {:ok, _} = put(context, %{"notify_url" => "https://hooks.example.test/runs"})

      assert {:error, error} = put(context, %{"notify_url" => "https://elsewhere.example.test/x"})
      assert error.message == "invalid_params"

      # The same list a pod's egress is held to. A plane that could reach hosts its own
      # workers cannot would be the widest hole in the deployment and nobody would be
      # looking at it.
      assert {:error, _} = Notify.allowed?("https://elsewhere.example.test/x")
    end
  end

  describe "a target the plane will take" do
    test "is saved, reported and sent to", context do
      {:ok, _} = put(context, %{"notify_url" => "https://hooks.example.test/runs"})

      assert [listed] =
               context.team |> Triggers.list() |> Enum.map(&Triggers.trigger_json/1)

      assert listed["notify_url"] == "https://hooks.example.test/runs"
    end

    test "is allowed to be absent, and announcing does nothing", context do
      {:ok, trigger} = put(context, %{})
      assert is_nil(trigger.notify_url)

      # A run whose trigger names nowhere is not an error and not a request.
      assert Triggers.announce("no-such-session", %{"state" => "done"}) == :ok
    end
  end

  describe "the request itself" do
    setup do
      # A real server on loopback, and the plane must not reach it. This is the whole
      # test: not that a check returns an error, but that nothing arrives.
      test = self()

      {:ok, listener} =
        start_supervised(
          {Bandit, plug: {Listener, test}, scheme: :http, port: 0, startup_log: false}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
      %{port: port}
    end

    test "never reaches a loopback listener, whatever is in the column", context do
      # Straight into the column, past the changeset: what is under test is the check at
      # *send*, and a test that could not write a bad value could only ever prove the
      # check at save.
      {:ok, trigger} = put(context, %{})

      {:ok, _} =
        trigger
        |> Ecto.Changeset.change(notify_url: "http://127.0.0.1:#{context.port}/rpc")
        |> Repo.update()

      assert {:error, reason} =
               Notify.deliver(
                 Triggers.get(context.team, "triage"),
                 run_for(trigger),
                 %{"state" => "done"}
               )

      assert reason =~ "loopback"
      refute_receive {:notified, _path}, 500
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp run_for(trigger) do
    %Triggers.Run{
      trigger_id: trigger.id,
      idempotency_key: "k-1",
      source: "schedule",
      session_id: "s-1",
      fired_at: DateTime.utc_now()
    }
  end

  defp put(context, attrs) do
    base = %{
      "name" => "triage",
      "principal" => context.principal.subject,
      "profile" => "dev",
      "source" => %{"kind" => "webhook", "provider" => "generic"},
      "prompt_template" => "do the thing"
    }

    Triggers.put(context.team, Map.merge(base, attrs), "root@example.test")
  end
end
