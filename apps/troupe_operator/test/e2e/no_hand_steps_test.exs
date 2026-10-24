defmodule Troupe.E2E.NoHandStepsTest do
  @moduledoc """
  A cluster needs no hand step that the chart, the operator or a checked precondition does
  not own (#765).

  Three that were a person's, asked of the cluster `scripts/remote-up` made, which takes
  none of them:

  - the Secrets a worker namespace mounts are the operator's copies of the ones beside the
    plane, and the profile says none is missing;
  - the ingress controller's namespace carries `troupe.dev/ingress=true` because the
    operator put it there, the kind values naming it, and every profile says so;
  - the plane logs in to OpenBao under a role with the policies `docs/admin/openbao.md`
    lists and nothing more, not a root token, so its check of its grants is the one a
    deployment meets: one grant taken away is named on the Overview with the lines that
    give it back, at the next look and with nothing restarted, and given back it is held
    again.

  OpenBao's root token is this suite's, for taking the grant away and giving it back.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}
  alias Troupe.KMS.Policy

  @moduletag :e2e
  @moduletag timeout: 600_000

  @root "troupe-dev-root"

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  describe "the worker namespace's Secrets" do
    test "are the operator's copies of the ones beside the plane, and none is missing" do
      namespace = World.worker_namespace(World.profile())

      for name <- ~w(troupe-object-store llm-credentials) do
        secret = json!(["get", "secret", name, "-n", namespace])
        source = json!(["get", "secret", name, "-n", World.namespace()])

        assert secret["metadata"]["labels"]["troupe.dev/managed"] == "operator",
               "#{namespace}/#{name} is not the operator's copy: #{inspect(secret["metadata"])}"

        assert secret["metadata"]["annotations"]["troupe.dev/copied-from"] ==
                 "#{World.namespace()}/#{name}"

        assert secret["data"] == source["data"]
      end

      assert %{"status" => "False"} = condition(World.profile(), "SecretMissing")
    end
  end

  describe "the ingress controller's namespace" do
    test "carries the label the operator put there, and every profile says it may reach the workers" do
      namespace = json!(["get", "namespace", "ingress-nginx", "--show-managed-fields"])
      assert namespace["metadata"]["labels"]["troupe.dev/ingress"] == "true"

      owners =
        for %{"manager" => manager, "fieldsV1" => fields} <-
              namespace["metadata"]["managedFields"],
            get_in(fields, ["f:metadata", "f:labels", "f:troupe.dev/ingress"]),
            do: manager

      assert "troupe-operator" in owners, "the label is not the operator's: #{inspect(owners)}"

      assert %{"status" => "False", "reason" => "Labelled"} =
               condition(World.profile(), "IngressNamespaceMissing")
    end
  end

  describe "the plane's OpenBao role" do
    setup do
      port = World.port_forward(World.namespace(), "svc/openbao", 8200)
      %{bao: "http://127.0.0.1:#{port}"}
    end

    test "carries the documented policies and no other, and the plane holds every grant",
         context do
      role = bao(context, :get, "auth/kubernetes/role/troupe-plane")
      assert role.status == 200, inspect(role.body)

      assert Enum.sort(role.body["data"]["token_policies"]) ==
               Enum.sort(for grant <- Policy.plane_grants(), do: grant.policy)

      check = openbao!()
      assert check["error"] == nil, inspect(check)
      assert check["ok"] == true, inspect(check["grants"])

      for grant <- check["grants"] do
        assert grant["ok"], "#{grant["policy"]}: #{grant["detail"]}"
      end
    end

    test "a grant taken away is named with the lines that give it back, and given back is held",
         context do
      grant = Enum.find(Policy.plane_grants(), &(&1.id == "erasure"))
      path = "sys/policies/acl/#{grant.policy}"

      restore = fn ->
        bao(context, :put, path, json: %{"policy" => Policy.grant_policy(grant)})
      end

      on_exit(restore)

      assert bao(context, :delete, path).status in [200, 204]

      World.eventually(fn -> not held?(grant.id) end,
        timeout: 60_000,
        what: "the Overview to say the plane lacks #{grant.policy}",
        explain: fn -> inspect(openbao!()) end
      )

      check = openbao!()
      assert check["ok"] == false
      lacking = Enum.find(check["grants"], &(&1["id"] == grant.id))
      assert lacking["required"] == true
      assert lacking["detail"] =~ "The plane's OpenBao role may not #{grant.for}"
      assert lacking["fix"] =~ "bao policy write #{grant.policy} - <<'POLICY'"

      for {rule, _capabilities} <- grant.rules do
        assert lacking["fix"] =~ ~s(path "#{rule}")
      end

      # The role keeps every policy it carries when the line adds this one.
      assert lacking["fix"] =~ "bao write auth/kubernetes/role/troupe-plane token_policies="

      for other <- Policy.plane_grants() do
        assert lacking["fix"] =~ other.policy
      end

      # Everything else is still held: one grant gone is said as that one.
      for other <- check["grants"],
          other["id"] != grant.id,
          do: assert(other["ok"], other["detail"])

      assert restore.().status in [200, 204]

      World.eventually(fn -> held?(grant.id) end,
        timeout: 60_000,
        what: "the Overview to say the plane holds #{grant.policy} again",
        explain: fn -> inspect(openbao!()) end
      )

      assert openbao!()["ok"] == true
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp openbao!, do: Plane.call!("admin.overview")["openbao"]

  defp held?(id), do: Enum.find(openbao!()["grants"] || [], &(&1["id"] == id))["ok"] == true

  defp condition(profile, type) do
    ["get", "workerprofile", profile, "-n", World.namespace()]
    |> json!()
    |> get_in(["status", "conditions"])
    |> Enum.find(&(&1["type"] == type))
  end

  defp json!(args), do: (args ++ ["-o", "json"]) |> World.kubectl!() |> Jason.decode!()

  # One call to OpenBao through the port-forward, as root.
  defp bao(context, method, path, opts \\ []) do
    body = if method in [:post, :put], do: [json: Keyword.get(opts, :json, %{})], else: []

    Req.request!(
      [
        method: method,
        url: "#{context.bao}/v1/#{path}",
        headers: [{"x-vault-token", @root}],
        retry: false
      ] ++ body
    )
  end
end
