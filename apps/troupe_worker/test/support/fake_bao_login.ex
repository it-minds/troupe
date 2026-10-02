defmodule Troupe.Worker.FakeBaoLogin do
  @moduledoc """
  OpenBao's Kubernetes auth login, in front of the development OpenBao, for the tests of a
  worker's own OpenBao identity (Decision 753).

  The development OpenBao has no Kubernetes to review a ServiceAccount token against, so its
  `auth/<mount>/login` is answered here: for a role this was told of, with a real client
  token the development OpenBao issues with that role's policies and lease, and for any
  other role with the `400` OpenBao gives a role it does not have. Every other request
  goes through to the development OpenBao as it came, so what a token may do, how long it
  lasts and whether it was revoked are OpenBao's answers and not this module's.

  Each login is sent to the test process: `{:fake_bao, :login, %{role, jwt, token}}` for
  one answered, `{:fake_bao, :refused, role}` for one refused.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Start one under the test's supervisor, in front of `upstream` and issuing tokens with
  `root_token`.
  """
  def start(opts) do
    test = self()

    agent =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               test: test,
               upstream: Keyword.fetch!(opts, :upstream),
               root: Keyword.fetch!(opts, :root_token),
               roles: %{}
             }
           end},
          id: {__MODULE__, :agent}
        )
      )

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {__MODULE__, agent}, port: 0, ip: {127, 0, 0, 1}, startup_log: false},
          id: {__MODULE__, :server}
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{agent: agent, address: "http://127.0.0.1:#{port}"}
  end

  @doc "Answer a login as `role` with a token carrying `policies` that lasts `ttl` seconds."
  def role(fake, role, policies, ttl \\ 3600) do
    Agent.update(fake.agent, &put_in(&1.roles[role], %{policies: policies, ttl: ttl}))
  end

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["v1", "auth", _mount, "login"]} = conn, agent) do
    {:ok, body, conn} = read_body(conn)
    %{"role" => role, "jwt" => jwt} = Jason.decode!(body)
    state = Agent.get(agent, & &1)

    case Map.fetch(state.roles, role) do
      {:ok, %{policies: policies, ttl: ttl}} ->
        auth = issue(state, policies, ttl)

        send(
          state.test,
          {:fake_bao, :login, %{role: role, jwt: jwt, token: auth["client_token"]}}
        )

        answer(conn, 200, %{"auth" => auth})

      :error ->
        send(state.test, {:fake_bao, :refused, role})
        answer(conn, 400, %{"errors" => ["invalid role name \"#{role}\""]})
    end
  end

  def call(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    upstream = Agent.get(agent, & &1.upstream)
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

    headers =
      for {name, value} <- conn.req_headers,
          name in ["x-vault-token", "content-type"],
          do: {name, value}

    {:ok, response} =
      [
        method: conn.method |> String.downcase() |> String.to_atom(),
        url: upstream <> conn.request_path <> query,
        headers: headers,
        retry: false,
        decode_body: false
      ]
      |> then(&if(body == "", do: &1, else: Keyword.put(&1, :body, body)))
      |> Req.request()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(response.status, response.body)
  end

  # A real token from the development OpenBao, so a policy, a lease and a revocation are
  # enforced by OpenBao rather than imagined here.
  defp issue(state, policies, ttl) do
    {:ok, %{status: 200, body: body}} =
      Req.request(
        method: :post,
        url: state.upstream <> "/v1/auth/token/create",
        headers: [{"x-vault-token", state.root}],
        json: %{"policies" => policies, "ttl" => "#{ttl}s", "renewable" => false},
        decode_body: true,
        retry: false
      )

    body["auth"]
  end

  defp answer(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
