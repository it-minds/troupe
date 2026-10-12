defmodule Troupe.E2E.IsolationTest do
  @moduledoc """
  What keeps one session from the pod it runs on, and one profile from another's keys.

  Two claims the unit suites make about pieces and this makes about a deployment.

  **A session's commands run in bubblewrap.** On a worker every command a session starts
  runs in a sandbox that holds the session's mounts and the system's read-only roots and
  nothing else of the pod: not the pod's processes, not the tokens the pod was given. A
  command is run through `shell.run`, over the WebSocket the plane names, which goes
  through the runner the agent's own `shell` tool uses: the same shell, reaper and
  sandbox. What it sees is set beside what the same lines see run on the pod by `kubectl
  exec`, outside any sandbox, so an absence is the sandbox's and not a pod that never had
  the thing.

  **A profile's OpenBao role reaches its own teams' session keys and nothing else.** An
  installation that gives each profile a role of its own writes the role, bound to the
  profile's namespace, and its policy, `Troupe.KMS.Policy.worker/2` for the teams granted
  to it; the operator names the role to the pod. This writes both into the development
  OpenBao the cluster runs, logs in as the profile's ServiceAccount with a token the API
  server issued for OpenBao's audience, and asks for what the role should and should not
  have. OpenBao checks the token with the API server, so the namespace it vouches for is
  Kubernetes' word, not this test's.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}
  alias Troupe.KMS.Policy
  alias Troupe.Protocol.{Client, Event}

  @moduletag :e2e
  @moduletag timeout: 600_000

  # What a command sees of where it runs: which process is the first in its PID namespace,
  # whether the worker's own BEAM is among the processes it can see, and whether the
  # token the pod logs in to OpenBao with is there for it to read.
  @probe """
  printf 'init=%s\\n' "$(cat /proc/1/comm)"
  printf 'beam=%s\\n' "$(cat /proc/[0-9]*/comm 2>/dev/null | grep -c beam)"
  if [ -e /var/run/secrets/troupe/kms-token ]; then echo token=present; else echo token=absent; fi
  """

  # The development OpenBao's root token, in `dev/kind/dependencies.yaml` in plain sight,
  # on a cluster nobody else uses.
  @root "troupe-dev-root"

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  describe "a command a session runs on a pod" do
    test "runs in bubblewrap, and sees none of the pod's processes or tokens", context do
      created = Plane.call!("session.create", %{"profile" => context.profile})
      id = created["session_id"]
      on_exit(fn -> Plane.call("session.erase", %{"session_id" => id}) end)

      assert created["endpoint"], "the session did not activate: #{inspect(created)}"

      client = Plane.attach!(created)

      {:ok, _subscription} =
        Client.subscribe(client, "session:" <> id, level: :detail, from_seq: 0)

      # `agent: false`, the terminal client's `!!`: the output goes to nobody's model, and
      # no model is needed for any of it.
      assert {:ok, %{"run_id" => run_id}} =
               Client.call(client, "shell.run", %{
                 "command_id" => Client.command_id(),
                 "session_id" => id,
                 "command" => @probe,
                 "agent" => false
               })

      ran = await_shell(run_id)
      assert ran["exit_status"] == 0, "the probe did not run in the session: #{inspect(ran)}"
      inside = facts(ran["output"])

      # The same lines on the pod itself, outside any sandbox: what the session would see if
      # its commands ran there.
      {output, 0} =
        World.exec(World.worker_namespace(context.profile), created["pod"], ["sh", "-c", @probe])

      outside = facts(output)

      assert outside["token"] == "present" and outside["beam"] != "0", """
      The probe, run on #{created["pod"]} itself, sees no token or no BEAM there, so their
      absence in the session would prove nothing: #{inspect(outside)}
      """

      refute outside["init"] == "bwrap"

      assert inside["init"] == "bwrap", """
      The first process a session's command sees is #{inspect(inside["init"])}, not
      bubblewrap: the command ran in the pod's own PID namespace. #{inspect(inside)}
      """

      assert inside["beam"] == "0",
             "a session's command can see the worker's BEAM: #{inspect(inside)}"

      assert inside["token"] == "absent", """
      A session's command can read /var/run/secrets/troupe/kms-token, the token the pod logs
      in to OpenBao with, and so every session key its role reaches.
      """
    end
  end

  describe "a profile's OpenBao role" do
    setup context do
      port = World.port_forward(World.namespace(), "svc/openbao", 8200)
      Map.put(context, :bao, "http://127.0.0.1:#{port}")
    end

    test "reads and writes its own teams' session keys, and nothing of anybody else's", context do
      namespace = World.worker_namespace(context.profile)
      role = role!(context)
      other = Plane.unique("e2e-other-team")
      key = Plane.unique("e2e-key")
      own = "secret/data/troupe/teams/#{context.team}/sessions/#{key}"
      theirs = "secret/data/troupe/teams/#{other}/sessions/#{key}"

      on_exit(fn ->
        bao(context, :delete, "secret/metadata/troupe/teams/#{context.team}/sessions/#{key}")
        bao(context, :delete, "secret/metadata/troupe/teams/#{other}/sessions/#{key}")
      end)

      # Another team's key, there to be refused.
      planted = bao(context, :post, theirs, json: %{"data" => %{"key" => "another team's"}})
      assert planted.status == 200, "writing #{theirs} as root: #{inspect(planted.body)}"

      token = login!(context, role, World.token(namespace, "troupe-worker", "troupe-kms"))

      # Its own team's: the half without which every refusal below could be a role that
      # reaches nothing at all.
      written = bao(context, :post, own, token: token, json: %{"data" => %{"key" => "its own"}})
      assert written.status == 200, "#{role} could not write #{own}: #{inspect(written.body)}"
      assert bao(context, :get, own, token: token).status == 200

      for {method, path, what} <- [
            {:get, theirs, "read another team's session key"},
            {:post, theirs, "write another team's session key"},
            {:delete, "secret/metadata/troupe/teams/#{context.team}/sessions/#{key}",
             "destroy its own team's session key"},
            {:get, "secret/data/troupe/people/#{Plane.subject()}/sessions/#{key}",
             "read a person's private session key"}
          ] do
        status =
          bao(context, method, path, token: token, json: %{"data" => %{"key" => "x"}}).status

        assert status == 403, "#{role} could #{what} (#{method} #{path} answered #{status})"
      end
    end

    test "is refused to a pod of another profile's namespace", context do
      role = role!(context)

      # A neighbour: the same ServiceAccount name, in another worker namespace. The
      # operator gives every profile's pods the same name, so the namespace is all that
      # tells them apart.
      neighbour = World.worker_namespace(Plane.unique("e2e-neighbour"))
      World.kubectl!(["create", "namespace", neighbour])
      on_exit(fn -> World.kubectl(["delete", "namespace", neighbour, "--wait=false"]) end)
      World.kubectl!(["create", "serviceaccount", "troupe-worker", "-n", neighbour])

      jwt = World.token(neighbour, "troupe-worker", "troupe-kms")

      refused =
        bao(context, :post, "auth/kubernetes/login",
          token: nil,
          json: %{"role" => role, "jwt" => jwt}
        )

      assert refused.status in [400, 403], """
      A pod of #{neighbour} logged in under #{role}, the role of #{context.profile}'s pods, and
      would read that profile's session keys: #{inspect(refused.body)}
      """

      # And the token is a good one: under the shared role, which every namespace may use,
      # it logs in. So the refusal above was the role's binding, not a token OpenBao could
      # not check.
      assert is_binary(login!(context, "troupe-worker", jwt))
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp await_shell(run_id) do
    receive do
      {:troupe_event, _topic, _session_id,
       %Event{type: "user_shell", data: %{"run_id" => ^run_id} = data}} ->
        data

      {:troupe_event, _topic, _session_id, _event} ->
        await_shell(run_id)
    after
      120_000 -> flunk("#{run_id} never ended: no user_shell for it in two minutes")
    end
  end

  defp facts(output) do
    for line <- String.split(output, "\n", trim: true),
        [name, value] <- [String.split(String.trim(line), "=", parts: 2)],
        into: %{},
        do: {name, value}
  end

  # What an installation writes for a profile that has a role of its own: its policy, for
  # the teams granted to it, and a role named for the profile, bound to the profile's
  # namespace, carrying it. Removed when the test ends.
  defp role!(context) do
    role = Policy.worker_role_name(context.profile)
    # The policy's name is the test's own: the development manifest already has a policy
    # called `troupe-worker-dev`, the wide one every worker's shared role carries.
    policy = Plane.unique("e2e-worker-role")

    # A role the cluster already has under that name is somebody's, and not this test's
    # to replace and then delete.
    assert bao(context, :get, "auth/kubernetes/role/#{role}").status == 404,
           "OpenBao already has a role #{role}; this test makes its own and removes it"

    on_exit(fn ->
      bao(context, :delete, "auth/kubernetes/role/#{role}")
      bao(context, :delete, "sys/policies/acl/#{policy}")
    end)

    written =
      bao(context, :put, "sys/policies/acl/#{policy}",
        json: %{"policy" => Policy.worker("secret", [context.team])}
      )

    assert written.status in 200..204, "writing #{policy}: #{inspect(written.body)}"

    bound =
      bao(context, :post, "auth/kubernetes/role/#{role}",
        json: %{
          "bound_service_account_names" => ["troupe-worker"],
          "bound_service_account_namespaces" => [World.worker_namespace(context.profile)],
          "audience" => "troupe-kms",
          "token_policies" => [policy],
          "token_ttl" => "10m"
        }
      )

    assert bound.status in 200..204, "writing #{role}: #{inspect(bound.body)}"
    role
  end

  defp login!(context, role, jwt) do
    response =
      bao(context, :post, "auth/kubernetes/login",
        token: nil,
        json: %{"role" => role, "jwt" => jwt}
      )

    case response do
      %{status: 200, body: %{"auth" => %{"client_token" => token}}} ->
        token

      %{status: status, body: body} ->
        flunk("logging in under #{role} answered #{status}: #{inspect(body)}")
    end
  end

  # One call to OpenBao through the port-forward, as root unless a token is given; `nil`
  # sends none, as a login does.
  defp bao(context, method, path, opts \\ []) do
    token = Keyword.get(opts, :token, @root)
    headers = if token, do: [{"x-vault-token", token}], else: []
    body = if method in [:post, :put], do: [json: Keyword.get(opts, :json, %{})], else: []

    Req.request!(
      [method: method, url: "#{context.bao}/v1/#{path}", headers: headers, retry: false] ++ body
    )
  end
end
