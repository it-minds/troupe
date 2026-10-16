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

  alias Troupe.Plane.{Sessions, Triggers}
  alias Troupe.Plane.Triggers.Notify

  defmodule Listener do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(test), do: test

    @impl Plug
    def call(conn, test) do
      send(test, {:notified, conn.request_path, Plug.Conn.get_req_header(conn, "host")})
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:notified_with, body})
      Plug.Conn.send_resp(conn, 200, "")
    end
  end

  @moduletag timeout: 60_000

  @answers %{
    "metadata.example.test" => [{100, 100, 100, 200}],
    "metadata-v6.example.test" => [{0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}],
    "metadata-mapped.example.test" => [{0, 0, 0, 0, 0, 0xFFFF, 0x6464, 0x64C8}],
    # What a DNS64 resolver answers for a name whose only address is the metadata one.
    "metadata-nat64.example.test" => [{0x64, 0xFF9B, 0, 0, 0, 0, 0x6464, 0x64C8}],
    "shared.example.test" => [{100, 64, 0, 1}],
    "shared-mapped.example.test" => [{0, 0, 0, 0, 0, 0xFFFF, 0x6440, 0x0001}],
    "link-local.example.test" => [{169, 254, 169, 254}],
    "loopback.example.test" => [{127, 0, 0, 1}],
    "both.example.test" => [{203, 0, 113, 5}, {100, 100, 100, 200}],
    "hooks.example.test" => [{203, 0, 113, 5}],
    "office.example.test" => [{10, 20, 0, 5}]
  }

  setup do
    team = team_with_grant("engineering", "dev", name: "engineering")
    ada = person("ada@example.test", ["engineering"])

    {:ok, principal, _secret} =
      principal!(team, %{name: "nightly", profiles: ["dev"], sponsor: ada.subject})

    # Everything the deployment allows, so that a refusal in these tests is a refusal
    # about the *target* rather than a policy that happened to say no to everything.
    Application.put_env(:troupe_plane, :egress_allowed, fn _host -> true end)
    on_exit(fn -> Application.delete_env(:troupe_plane, :egress_allowed) end)

    # What a name answers at send, said here rather than asked of the network. A name not
    # listed answers nothing.
    Application.put_env(:troupe_plane, :notify_resolver, &Map.get(@answers, &1, []))
    on_exit(fn -> Application.delete_env(:troupe_plane, :notify_resolver) end)

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

    test "is refused at a cloud's metadata address and in the shared address space", context do
      # Issue #588. Two clouds' metadata services answer outside link-local, at
      # `fd00:ec2::254` and `100.100.100.200`, in every spelling a worker's are refused in
      # (Decision 856), and the second in the shared address space, which is refused
      # whole. The plane holds the same list a worker does, and names what it found.
      refused = [
        {"http://[fd00:ec2::254]/latest", "is not a cloud metadata address"},
        {"http://[FD00:EC2:0:0::254]/latest", "is not a cloud metadata address"},
        {"http://100.100.100.200/latest", "is not a cloud metadata address"},
        {"http://[::ffff:100.100.100.200]/latest", "is not a cloud metadata address"},
        # Older spellings of the same address, which a connection takes as one.
        {"http://1684301000/latest", "is not a cloud metadata address"},
        {"http://0144.0144.0144.0310/latest", "is not a cloud metadata address"},
        # IPv6 spellings of a v4 address: NAT64's well-known prefix, IPv4-compatible, and
        # 6to4, each judged as the v4 address it names.
        {"http://[64:ff9b::6464:64c8]/latest", "is not a cloud metadata address"},
        {"http://[64:ff9b::100.100.100.200]/latest", "is not a cloud metadata address"},
        {"http://[::100.100.100.200]/latest", "is not a cloud metadata address"},
        {"http://[2002:6464:64c8::1]/latest", "is not a cloud metadata address"},
        {"http://[64:ff9b::a9fe:a9fe]/latest", "is not link-local"},
        {"http://[2002:a9fe:a9fe::]/latest", "is not link-local"},
        {"http://[64:ff9b::7f00:1]/rpc", "is not loopback"},
        {"http://100.64.0.1/x", "is not in the shared address space"},
        {"http://100.127.255.254/x", "is not in the shared address space"},
        {"http://100.100.100.201/x", "is not in the shared address space"},
        {"http://[::ffff:100.64.0.1]/x", "is not in the shared address space"},
        {"http://[64:ff9b::6440:1]/x", "is not in the shared address space"},
        # And what was refused before still is, and says so as it did.
        {"http://169.254.169.254/latest/meta-data/", "is not link-local"},
        {"http://[::ffff:169.254.169.254]/x", "is not link-local"},
        {"http://[fe80::1]/x", "is not link-local"},
        {"http://127.0.0.1:4000/rpc", "is not loopback"},
        {"http://[::1]:4000/rpc", "is not loopback"},
        {"http://0.0.0.0/x", "is not the unspecified address"},
        {"http://224.0.0.1/x", "is not multicast"}
      ]

      for {url, said} <- refused do
        assert Notify.validate(url) == {:error, said}, "#{url} was not refused as #{said}"
        assert Notify.allowed?(url) == {:error, said}
      end

      # The sentence reaches whoever saves it.
      assert {:error, error} = put(context, %{"notify_url" => "http://[fd00:ec2::254]/"})
      assert error.data.reason =~ "is not a cloud metadata address"

      # The edges, and the private ranges the egress allowlist governs instead.
      for url <- ~w(http://100.63.255.255/x http://100.128.0.0/x http://[fd00:ec2::253]/x
                    http://[fd00::5]/x http://10.20.0.5/x https://203.0.113.5/x
                    https://[64:ff9b::cb00:7105]/x https://[2002:cb00:7105::1]/x) do
        assert Notify.validate(url) == :ok, "#{url} was refused"
        assert Notify.allowed?(url) == :ok, "#{url} was refused at send"
      end
    end

    test "is refused at send when a name resolves to a metadata or shared address" do
      # A name says nothing about where it leads when it is saved; at send it is asked,
      # here of a stand-in rather than the network, and every answer is held to the list.
      for {host, said} <- [
            {"metadata.example.test", "is not a cloud metadata address"},
            {"metadata-v6.example.test", "is not a cloud metadata address"},
            {"metadata-mapped.example.test", "is not a cloud metadata address"},
            {"metadata-nat64.example.test", "is not a cloud metadata address"},
            {"shared.example.test", "is not in the shared address space"},
            {"shared-mapped.example.test", "is not in the shared address space"},
            {"link-local.example.test", "is not link-local"},
            {"loopback.example.test", "is not loopback"},
            # One bad answer among good ones is enough.
            {"both.example.test", "is not a cloud metadata address"}
          ] do
        url = "https://#{host}/runs"

        assert Notify.validate(url) == :ok
        assert Notify.allowed?(url) == {:error, said}, "#{host} was not refused as #{said}"

        assert Notify.deliver(
                 %Triggers.Trigger{name: "triage", notify_url: url},
                 %Triggers.Run{},
                 %{"state" => "done"}
               ) == {:error, said}
      end

      assert Notify.allowed?("https://hooks.example.test/runs") == :ok
      assert Notify.allowed?("https://office.example.test/runs") == :ok
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
      assert Triggers.announce("no-such-session") == :ok
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
      refute_receive {:notified, _path, _host}, 500
    end
  end

  describe "the address it is sent to" do
    setup do
      # One of this machine's own addresses that the check allows, as a webhook receiver
      # in the next namespace would have: loopback, where the test above listens, is not.
      address = own_address()

      {:ok, listener} =
        start_supervised(
          {Bandit,
           plug: {Listener, self()}, scheme: :http, ip: address, port: 0, startup_log: false}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
      %{address: address, port: port}
    end

    test "is the one the check passed, not what the name answers next", context do
      # The name answers the checked address once and loopback ever after, as a rebind
      # with a short lifetime or a round robin would. The request goes where the check
      # looked and the connection asks nobody again; before, it asked DNS itself.
      lookups = :counters.new(1, [])

      Application.put_env(:troupe_plane, :notify_resolver, fn
        "rebind.example.test" ->
          :counters.add(lookups, 1, 1)
          if :counters.get(lookups, 1) == 1, do: [context.address], else: [{127, 0, 0, 1}]

        _other ->
          []
      end)

      trigger = %Triggers.Trigger{
        name: "triage",
        notify_url: "http://rebind.example.test:#{context.port}/runs"
      }

      assert Notify.deliver(trigger, run_for(trigger), %{"state" => "done"}) == :ok

      # It arrived at the checked address, carrying the name it was given.
      assert_receive {:notified, "/runs", ["rebind.example.test:" <> port]}, 5_000
      assert port == to_string(context.port)
      assert :counters.get(lookups, 1) == 1
    end

    # A run that opened a draft pull request says where it is when it ends, which is where
    # a person goes next; a run that opened none says so with a null.
    test "carries the run's pull request, as a link", context do
      Application.put_env(:troupe_plane, :notify_resolver, fn
        "hooks.example.test" -> [context.address]
        _other -> []
      end)

      {:ok, trigger} =
        put(context, %{"notify_url" => "http://hooks.example.test:#{context.port}/runs"})

      {:ok, revision} = Triggers.revise(trigger)
      url = "https://github.com/example-org/widgets/pull/12"

      for {id, github} <- [
            {"s-notify-pr-#{System.unique_integer([:positive])}",
             %{"branch" => "troupe/fix-12", "pull_request" => %{"number" => 12, "url" => url}}},
            {"s-notify-none-#{System.unique_integer([:positive])}", nil}
          ] do
        {:ok, session} =
          Sessions.create(%{id: id, owner_subject: "svc:engineering/nightly", profile: "dev"})

        {:ok, _} =
          session |> Ecto.Changeset.change(github: github, status: "done") |> Repo.update()

        {:ok, _run} =
          %Triggers.Run{}
          |> Triggers.Run.changeset(%{
            trigger_id: trigger.id,
            revision_id: revision.id,
            idempotency_key: "k-#{id}",
            session_id: id,
            fired_at: DateTime.utc_now(),
            source: "webhook",
            state: "created"
          })
          |> Repo.insert()

        assert Triggers.announce(id) == :ok
        assert_receive {:notified_with, body}, 5_000
        sent = Jason.decode!(body)
        assert sent["session_id"] == id
        assert sent["pull_request"] == if(github, do: url)
        assert Map.has_key?(sent, "pull_request")
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp own_address do
    {:ok, interfaces} = :inet.getifaddrs()

    allowed =
      for {_name, options} <- interfaces,
          {:addr, {_a, _b, _c, _d} = address} <- options,
          Notify.allowed?("http://#{:inet.ntoa(address)}/") == :ok,
          do: address

    case allowed do
      [address | _rest] -> address
      [] -> flunk("needs an interface with an IPv4 address the check allows, not loopback")
    end
  end

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
