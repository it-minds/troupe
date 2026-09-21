defmodule Troupe.E2E.Plane do
  @moduledoc """
  The plane as a client sees it: sign in, then call methods over `/rpc`.

  Everything here goes through the ingress, with a token the identity provider issued.
  There is no private door — the operator may not depend on `troupe_plane` and this
  deliberately does not want one, because a suite that reached into the plane's modules
  would prove things about our code rather than about the thing that is deployed.

  ## Signing in without a browser

  `troupe login` uses the device flow, which needs a person and a browser. A CI runner
  has neither, so the development Dex enables the resource-owner password grant — in
  `dev/kind/dependencies.yaml` and nowhere else, on a cluster whose passwords are in this
  repository in plain sight. The id token it answers is exchanged at the plane's
  `/auth/exchange` for a plane token exactly as a real client's would be.
  """

  alias Troupe.E2E.World
  alias Troupe.Protocol.{Client, Event}

  @person "ada@example.test"
  @password "troupe"
  @client "troupe"

  # Seconds of life left below which a cached token is replaced rather than sent: longer
  # than the slowest single call, so a token is never sent with time left and received
  # without any.
  @renew_before 120

  @doc """
  The subject this suite signs in as, as the plane knows it.

  Asked rather than assumed. `@person` is the username Dex takes at the password grant;
  the *subject* is the opaque string Dex mints for it — `CgNhZGESBWxvY2Fs` rather than
  `ada@example.test` — and anything the plane matches a person by matches the subject.
  Sponsoring a principal with the username named a person the plane has never heard of.

  Cached for the run, like the token, because it cannot change within one.
  """
  @spec subject() :: String.t()
  def subject do
    case :persistent_term.get({__MODULE__, :subject}, nil) do
      nil ->
        subject = call!("me")["subject"]
        :persistent_term.put({__MODULE__, :subject}, subject)
        subject

      subject ->
        subject
    end
  end

  @doc "The username this suite signs in with at the identity provider."
  @spec person() :: String.t()
  def person, do: @person

  @doc """
  A plane token for the development person, who is a platform admin and in `engineering`.

  Cached, because every test would otherwise spend two round trips on the same answer —
  but only until shortly before it expires. A plane token lives fifteen minutes and the
  suite takes longer than that: cached for the whole run, every test from minute sixteen
  on was refused as `expired`, and the release gate with them.
  """
  @spec token() :: String.t()
  def token do
    now = System.os_time(:second)

    case :persistent_term.get({__MODULE__, :token}, nil) do
      {token, expires_at} when expires_at - now > @renew_before ->
        token

      _missing_or_expiring ->
        {token, expires_at} = sign_in()
        :persistent_term.put({__MODULE__, :token}, {token, expires_at})
        token
    end
  end

  @doc "Forget the cached token. For a test that deactivates the person on purpose."
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase({__MODULE__, :token})
    :ok
  end

  @doc "One JSON-RPC call to the plane, as the person. Raises on a transport failure."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def call(method, params \\ %{}, opts \\ []) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

    response =
      Req.post!(World.plane_url() <> "/rpc",
        json: body,
        headers: [{"authorization", "Bearer " <> Keyword.get(opts, :token, token())}],
        retry: false,
        receive_timeout: Keyword.get(opts, :timeout, 30_000)
      )

    case response.body do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
      other -> {:error, %{"message" => "unexpected", "data" => other}}
    end
  end

  @doc "The same, raising the plane's own error rather than returning it."
  @spec call!(String.t(), map(), keyword()) :: map()
  def call!(method, params \\ %{}, opts \\ []) do
    case call(method, params, opts) do
      {:ok, result} -> result
      {:error, error} -> raise "#{method} refused: #{inspect(error)}"
    end
  end

  @doc """
  Everything a session needs, through the plane's own admin surface.

  A profile the plane knows about, a team over the development person's group, a grant
  between them, and a bundle on the channel the profile follows. Idempotent, because
  these run against a cluster that is not reset between tests: everything here is a
  statement of what should be true rather than an instruction to change something.

  `scripts/remote-up` creates the WorkerProfile with `kubectl`, deliberately — the panel
  needs a platform admin and a platform admin needs somebody to have signed in, which on
  a fresh cluster nobody has. That leaves the *plane* not knowing the profile, because
  `Fleet.list_profiles/0` reads a table rather than the cluster, and a profile the plane
  does not know cannot be granted to a team. So the suite writes it through the plane,
  which is the path a platform admin actually uses and is worth going through.
  """
  @spec ready!(keyword()) :: map()
  def ready!(opts \\ []) do
    profile = Keyword.get(opts, :profile, World.profile())
    group = Keyword.get(opts, :group, "engineering")
    channel = Keyword.get(opts, :channel, "stable")

    profile!(profile, channel)
    team = team!(group, profile)
    bundle = publish!(channel, Keyword.get(opts, :bundle, default_bundle()))
    reclaim(profile)

    %{profile: profile, team: team["name"] || group, channel: channel, bundle: bundle}
  end

  @doc """
  Erase what earlier runs left behind on this profile.

  A world owns what it created, and across runs that has to mean something: a suite that
  leaves two sessions on a pod with two slots is a suite whose next run cannot place
  anything — and the failure arrives as `capacity` in whichever test happens to be
  third, which is a fixture problem wearing a product problem's clothes.

  Erasure rather than archival, because a session that ever ran is erased and because the
  slot comes back either way. This is only safe on a cluster the suite owns, which is
  what `mix troupe.e2e` refusing any context but the kind one is for.
  """
  @spec reclaim(String.t()) :: :ok
  def reclaim(profile) do
    # The admin method, not the harness one. A session a trigger made belongs to a
    # service principal, and `session.erase` on the harness asks whether the caller
    # administers *that* session; the platform admin road is the one that always works
    # and is the one a person clearing up would use.
    stale =
      "admin.sessions.list"
      |> call!(%{"filter" => %{"profile" => profile}})
      |> List.wrap()
      |> Enum.reject(&(&1["state"] == "erased"))

    for session <- stale do
      case call("admin.session.erase", %{"session_id" => session["id"], "confirm" => session["id"]}) do
        {:ok, _} -> :ok
        {:error, error} -> raise "could not reclaim #{session["id"]}: #{inspect(error)}"
      end
    end

    :ok
  end

  @doc """
  What a profile of this world looks like, as `admin.profile.put` takes it.

  Separate from `profile!/2` because a test that wants a profile of its *own* — one it can
  scale to zero without the rest of the suite noticing — needs the same image and channel
  and a different name.
  """
  @spec profile_attrs(String.t(), String.t()) :: map()
  def profile_attrs(name, channel) do
    %{
      "name" => name,
      "image" => image(),
      "size_class" => "standard",
      "spec" => %{"configBundleChannel" => channel}
    }
  end

  @doc """
  A name nothing else on this plane has, across runs as well as within one.

  `System.unique_integer/1` counts from zero in each VM, so a second run of the suite
  invents the same names as the first — which is fine for a profile, whose teardown
  removes it, and not fine for a service principal, whose teardown *disables* it and
  leaves the row. The second run then collides on the subject's unique index in a setup
  block, which reads like a product refusal and is a fixture counting from zero.
  """
  @spec unique(String.t()) :: String.t()
  def unique(prefix) do
    "#{prefix}-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
  end

  @doc "Give a team a profile. Idempotent, like everything else here."
  @spec grant(String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def grant(team, profile) do
    call("admin.team.grant", %{"name" => team, "profile" => profile})
  end

  @doc "A profile the plane knows about, matching the one the operator is already running."
  @spec profile!(String.t(), String.t()) :: map()
  def profile!(name, channel) do
    call!("admin.profile.put", %{
      "profile" => %{
        "name" => name,
        "image" => image(),
        # Standard puts four sessions on a worker, because a run of this suite makes
        # several and a worker with two slots turns the third test into a `capacity`
        # failure that is about the fixture and reads like the product.
        "size_class" => "standard",
        # And one kept warm, so the shared profile never scales to zero underneath a test
        # that is about something else. The test that is about scaling to zero sets up its
        # own profile and says so.
        "warm_workers" => 1,
        "spec" => %{"configBundleChannel" => channel}
      }
    })
  end

  # Whatever the operator already gave the running pods, so writing the profile through
  # the plane does not replace the image out from under a session.
  defp image do
    repo =
      World.kubectl!([
        "get",
        "workerprofile",
        World.profile(),
        "-n",
        World.namespace(),
        "-o",
        "jsonpath={.spec.image.repository}:{.spec.image.tag}"
      ])

    if repo == ":", do: "ghcr.io/objective-mj/troupe-worker:dev", else: repo
  end

  # The smallest bundle a session can run on: one agent, no skills, no MCP servers.
  # Tests that need more publish their own.
  defp default_bundle do
    %{
      "schema" => 1,
      "agents" => [
        %{
          "name" => "prober",
          "definition" => "---
mode: primary
---
You are a helpful assistant on a cluster."
        }
      ]
    }
  end

  @doc """
  A team over the development person's group, with a grant on a profile.

  Idempotent, because these run against a cluster that is not reset between them: a team
  that already exists is enabled again and a grant already given is given again, both of
  which the plane treats as the same statement rather than as a second one.
  """
  @spec team!(String.t(), String.t(), map()) :: map()
  def team!(group, profile, attrs \\ %{}) do
    enabled =
      case call("admin.team.enable", %{"group" => group, "attrs" => attrs}) do
        {:ok, team} -> team
        # Already a team. Its name is the group's unless somebody renamed it, and the
        # listing is the authority on that rather than a guess.
        {:error, _} -> find_team!(group)
      end

    name = enabled["name"] || group
    _ = call("admin.team.grant", %{"name" => name, "profile" => profile})
    Map.put(enabled, "name", name)
  end

  defp find_team!(group) do
    teams = call!("admin.teams.list")

    Enum.find(List.wrap(teams), &(&1["group"] == group or &1["name"] == group)) ||
      raise "no team for group #{group}"
  end

  @doc "Publish a bundle on a channel and answer its version and hash."
  @spec publish!(String.t(), map()) :: map()
  def publish!(channel, content) do
    call!("admin.bundle.publish", %{"channel" => channel, "content" => content})
  end

  @doc "Who the plane thinks the caller is. The cheapest proof a token works."
  @spec me() :: map()
  def me, do: call!("me")

  @doc """
  Attach to the pod the plane named, over a real WebSocket through the ingress.

  This is the whole point of the endpoint the plane hands back: the plane is not on the
  path of a session's content, so reading a log means talking to the pod. The URL is the
  worker's own — `ws://<ordinal>-<profile>.workers.localtest.me/v1/socket` — which is why
  `scripts/e2e` teaches the container where those names live.
  """
  @spec attach!(map()) :: pid()
  def attach!(%{"endpoint" => endpoint, "token" => token}) do
    url = World.reachable(endpoint)
    client = dial(url, token, System.monotonic_time(:millisecond) + 120_000)
    ExUnit.Callbacks.on_exit(fn -> Client.close(client) end)
    client
  end

  # Retried, because a pod that has just replaced another becomes reachable in stages:
  # the plane knows it has enrolled before the ingress has endpoints for it, and in
  # between the upgrade is refused with a 503 that means "not yet" rather than "no". A
  # test that took the first answer as final would be failing on timing, not behaviour.
  defp dial(url, token, deadline) do
    case Client.connect(url: url, token: token, timeout: 30_000) do
      {:ok, client} ->
        client

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "could not attach to #{url}: #{inspect(reason)}"
        end

        Process.sleep(2_000)
        dial(url, token, deadline)
    end
  end

  @doc """
  Every durable event in a session's log, oldest first, read from the pod.

  `subscribe` at `detail` replays history before it streams, which is how a client that
  has just attached catches up — and is the only road to a log that does not involve
  reading object storage with a key.
  """
  @spec history!(pid(), String.t()) :: [Event.t()]
  def history!(client, session_id) do
    {:ok, _subscription} =
      Client.subscribe(client, "session:" <> session_id,
        level: :detail,
        from_seq: 0
      )

    collect([], 5_000)
  end

  # Until the replay goes quiet. There is no "that was the last one" in the stream — a
  # subscription that has caught up simply keeps waiting — so silence is the signal, and
  # the timeout is generous because a cluster's is longer than a laptop's.
  defp collect(events, timeout) do
    receive do
      {:troupe_event, _topic, _session_id, event} -> collect([event | events], timeout)
    after
      timeout -> Enum.reverse(events)
    end
  end

  defp sign_in do
    id_token = id_token()

    %{status: 200, body: %{"token" => token, "expires_at" => expires_at}} =
      Req.post!(World.plane_url() <> "/auth/exchange",
        json: %{"id_token" => id_token},
        retry: false
      )

    {token, expires_at}
  end

  @doc """
  The identity provider's own token for the development person.

  The A2A facade takes one of these rather than a plane token: it exchanges the caller's
  *credential* at the plane on every request and holds nothing of its own, so what
  crosses is the thing the provider issued. Exposed because the cluster suite has to
  present what a real caller presents.
  """
  @spec id_token!() :: String.t()
  def id_token!, do: id_token()

  defp id_token do
    response =
      Req.post!(World.issuer() <> "/token",
        form: [
          grant_type: "password",
          client_id: @client,
          username: @person,
          password: @password,
          scope: "openid profile email groups"
        ],
        retry: false
      )

    case response do
      %{status: 200, body: %{"id_token" => id_token}} ->
        id_token

      %{status: status, body: body} ->
        raise """
        e2e: the identity provider would not sign #{@person} in (#{status}): #{inspect(body)}

        The password grant is what this suite logs in with, and it is enabled in
        dev/kind/dependencies.yaml. A cluster brought up before that was added has a Dex
        that will refuse: re-run scripts/remote-up.
        """
    end
  end
end
