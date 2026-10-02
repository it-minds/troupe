defmodule Troupe.Worker.BaoLoginTest do
  @moduledoc """
  A worker logs in to OpenBao as its own role, and keeps the login (issue #336, Decision
  753).

  A pod logs in by Kubernetes auth under the role its pod is given in `TROUPE_BAO_ROLE`,
  which is where an installation that makes a role per profile binds that profile's
  policy, and `troupe-worker`, the one role every pod shares, where it is given none. The
  client token is used for every request until shortly before its lease ends, asked for
  once more after a `403`, and is in no log line, no process state and no event.

  The login is a fake (`FakeBaoLogin`), because the development OpenBao has no Kubernetes
  to review a ServiceAccount token against; the tokens it hands out are the development
  OpenBao's own, with a real policy and lease, and every other request is OpenBao's.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.KMS.{OpenBao, Policy}
  alias Troupe.KMS.OpenBao.Login
  alias Troupe.Worker.FakeBaoLogin

  @moduletag timeout: 120_000

  setup context do
    if context[:store] do
      unique = System.unique_integer([:positive])
      upstream = bao_address()
      fake = FakeBaoLogin.start(upstream: upstream, root_token: root_token())

      # The policy a profile's role carries, for this test's team: what the pod's token
      # may do is OpenBao's to enforce.
      policy = "troupe-worker-test#{unique}"
      put_policy!(policy, Policy.worker("secret", [context.team]))

      jwt = "eyJhbGciOiJSUzI1NiJ9.projected-#{unique}.signature"
      jwt_path = Path.join(context.base, "kms-token")
      File.write!(jwt_path, jwt <> "\n")

      previous = Application.get_env(:troupe_worker, :kms)
      previous_path = Application.get_env(:troupe_worker, :service_account_token_path)
      previous_token = System.get_env("TROUPE_BAO_TOKEN")
      System.delete_env("TROUPE_BAO_TOKEN")

      # A pod's configuration: no static token, so the pod logs in.
      Application.put_env(:troupe_worker, :kms, address: fake.address, mount: "secret")
      Application.put_env(:troupe_worker, :service_account_token_path, jwt_path)

      on_exit(fn ->
        Application.put_env(:troupe_worker, :kms, previous)

        if previous_path,
          do: Application.put_env(:troupe_worker, :service_account_token_path, previous_path),
          else: Application.delete_env(:troupe_worker, :service_account_token_path)

        if previous_token, do: System.put_env("TROUPE_BAO_TOKEN", previous_token)
        delete_policy(policy)
      end)

      %{fake: fake, policy: policy, jwt: jwt, jwt_path: jwt_path}
    else
      :ok
    end
  end

  describe "the role" do
    test "is the one the pod is given in TROUPE_BAO_ROLE", context do
      context = requires_tier(context)
      FakeBaoLogin.role(context.fake, "troupe-worker-dev", [context.policy])

      # What a pod's release reads at boot, from the environment the operator wrote.
      worker =
        with_env(
          %{
            "TROUPE_WORKER_AUTOSTART" => "true",
            "TROUPE_BAO_ROLE" => "troupe-worker-dev",
            "TROUPE_BAO_ADDR" => context.fake.address,
            "TROUPE_KMS_TOKEN_PATH" => context.jwt_path
          },
          fn -> runtime_config()[:troupe_worker] end
        )

      Application.put_env(:troupe_worker, :kms, worker[:kms])

      Application.put_env(
        :troupe_worker,
        :service_account_token_path,
        worker[:service_account_token_path]
      )

      start_supervised!(Login)

      assert {:ok, _key} = OpenBao.create(context.team, context.session_id)
      assert_received {:fake_bao, :login, %{role: "troupe-worker-dev", jwt: jwt}}
      assert jwt == context.jwt
      refute_received {:fake_bao, :refused, _role}
    end

    test "is troupe-worker when the pod is given none", context do
      context = requires_tier(context)
      FakeBaoLogin.role(context.fake, "troupe-worker", [context.policy])

      kms =
        with_env(
          %{
            "TROUPE_WORKER_AUTOSTART" => "true",
            "TROUPE_BAO_ROLE" => nil,
            "TROUPE_BAO_ADDR" => context.fake.address
          },
          fn -> runtime_config()[:troupe_worker][:kms] end
        )

      Application.put_env(:troupe_worker, :kms, kms)
      start_supervised!(Login)

      assert {:ok, _key} = OpenBao.create(context.team, context.session_id)
      assert_received {:fake_bao, :login, %{role: "troupe-worker"}}
    end
  end

  describe "the login" do
    test "is made once and used for every request", context do
      context = requires_tier(context)
      FakeBaoLogin.role(context.fake, "troupe-worker", [context.policy])
      start_supervised!(Login)

      other = Troupe.Session.generate_id()

      assert {:ok, key} = OpenBao.create(context.team, context.session_id)
      assert {:ok, ^key} = OpenBao.fetch(context.team, context.session_id)
      assert {:ok, ^key} = OpenBao.fetch(context.team, context.session_id)
      assert OpenBao.exists?(context.team, context.session_id)
      assert {:ok, _} = OpenBao.create(context.team, other)
      assert {:ok, _} = OpenBao.fetch(context.team, other)

      assert_received {:fake_bao, :login, %{role: "troupe-worker"}}
      refute_received {:fake_bao, :login, _second}
    end

    test "is made again shortly before its lease ends, without a restart", context do
      context = requires_tier(context)
      FakeBaoLogin.role(context.fake, "troupe-worker", [context.policy], 6)
      login = start_supervised!(Login)

      assert {:ok, key} = OpenBao.create(context.team, context.session_id)
      assert_received {:fake_bao, :login, %{token: first}}

      assert {:ok, ^key} = OpenBao.fetch(context.team, context.session_id)
      refute_received {:fake_bao, :login, _early}

      # Past three quarters of its six seconds and before its end: the next request logs
      # in again rather than setting out with a token about to run out.
      Process.sleep(4_700)

      assert {:ok, ^key} = OpenBao.fetch(context.team, context.session_id)
      assert_received {:fake_bao, :login, %{token: second}}
      assert second != first
      refute_received {:fake_bao, :login, _third}
      assert Process.alive?(login)
    end

    test "is made once more after a 403, and the second 403 stands", context do
      context = requires_tier(context)
      FakeBaoLogin.role(context.fake, "troupe-worker", [context.policy])
      start_supervised!(Login)

      assert {:ok, key} = OpenBao.create(context.team, context.session_id)
      assert_received {:fake_bao, :login, %{token: first}}

      # OpenBao stops honouring it: one new login, and the request works.
      revoke!(first)
      assert {:ok, ^key} = OpenBao.fetch(context.team, context.session_id)
      assert_received {:fake_bao, :login, %{token: second}}
      refute_received {:fake_bao, :login, _third}

      # A token that may not read the key, even one just issued: one login more and no
      # third, and the refusal is the answer.
      FakeBaoLogin.role(context.fake, "troupe-worker", ["default"])
      revoke!(second)

      capture_log(fn ->
        assert {:error, :forbidden} = OpenBao.fetch(context.team, context.session_id)
      end)

      assert_received {:fake_bao, :login, _third}
      refute_received {:fake_bao, :login, _fourth}
    end
  end

  describe "the token" do
    test "is in no log line and no process state", context do
      context = requires_tier(context)
      FakeBaoLogin.role(context.fake, "troupe-worker", [context.policy])
      login = start_supervised!(Login)

      {first, log} =
        with_log(fn ->
          assert {:ok, _key} = OpenBao.create(context.team, context.session_id)
          assert_received {:fake_bao, :login, %{token: first}}
          revoke!(first)
          assert {:ok, _key} = OpenBao.fetch(context.team, context.session_id)

          # And a refused login, which is logged.
          Application.put_env(:troupe_worker, :kms,
            address: context.fake.address,
            mount: "secret",
            role: "troupe-worker-gone"
          )

          assert {:error, :forbidden} = OpenBao.fetch(context.team, context.session_id)
          first
        end)

      assert_received {:fake_bao, :login, %{token: second}}
      assert log =~ "troupe-worker-gone"

      for token <- [first, second] do
        refute log =~ token
        refute inspect(:sys.get_status(login)) =~ token
      end

      refute log =~ context.jwt
    end

    test "is in no event of a session the pod opened with it", context do
      context = requires_tier(context)
      FakeBaoLogin.role(context.fake, "troupe-worker", [context.policy])
      start_supervised!(Login)

      assert {:ok, _} = activate(context, steps: [{:text, "keys in hand"}])
      run_turn(context.session_id, "say something", 20_000)
      assert_received {:fake_bao, :login, %{token: token}}

      logged =
        context.session_id
        |> Troupe.replay_from(0)
        |> Enum.map(&Map.take(&1, [:type, :agent, :data]))
        |> Jason.encode!()

      assert logged =~ "keys in hand"
      refute logged =~ token
      refute logged =~ context.jwt
    end
  end

  # -- helpers ----------------------------------------------------------------

  # `config/runtime.exs` as a release reads it, in the environment `vars` describes; a
  # `nil` is a variable that is not set.
  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {name, value} -> put_env(name, value) end)
    end
  end

  defp put_env(name, nil), do: System.delete_env(name)
  defp put_env(name, value), do: System.put_env(name, value)

  defp runtime_config do
    "../../../../../config/runtime.exs"
    |> Path.expand(__DIR__)
    |> Config.Reader.read!(env: :prod, target: :host)
  end

  defp bao_address,
    do: Application.get_env(:troupe_worker, :kms, [])[:address] || "http://localhost:28200"

  defp root_token,
    do: Application.get_env(:troupe_worker, :kms, [])[:token] || "troupe-dev-root"

  defp put_policy!(name, document) do
    {:ok, %{status: status}} = bao(:put, "/v1/sys/policies/acl/#{name}", %{"policy" => document})
    true = status in 200..299
  end

  defp delete_policy(name), do: bao(:delete, "/v1/sys/policies/acl/#{name}", nil)

  defp revoke!(token) do
    {:ok, %{status: status}} = bao(:post, "/v1/auth/token/revoke", %{"token" => token})
    true = status in 200..299
  end

  defp bao(method, path, body) do
    [
      method: method,
      url: "http://localhost:28200" <> path,
      headers: [{"x-vault-token", "troupe-dev-root"}],
      retry: false
    ]
    |> then(fn request -> if body, do: Keyword.put(request, :json, body), else: request end)
    |> Req.request()
  end
end
