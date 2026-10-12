defmodule Troupe.Plane.FakeGitHub do
  @moduledoc """
  GitHub, as much of it as the plane's App and a pod's clone use, in the test VM.

  A GitHub Enterprise Server's shape, since that is the one whose API and git share a
  host: the API under `/api/v3`, a repository at `/<owner>/<name>.git`. Three things are
  answered, each checked the way GitHub checks it:

  - **an installation token** (`POST /api/v3/app/installations/<id>/access_tokens`) for a
    request carrying an App JWT that verifies, RS256, against the public half of the key
    the test registered for that App, with `iss` the App's id, not expired and at most ten
    minutes long. The token is narrowed to the `repositories` and `permissions` asked for,
    which must be within the installation's, and lives `ttl` seconds (an hour unless told);
  - **a smart-HTTP clone** of a test repository (`GET .../info/refs?service=git-upload-pack`
    and `POST .../git-upload-pack`, served by the real `git upload-pack`), for Basic
    credentials whose password is a token this issued, unexpired, whose installation is
    the repository's owner and whose `repositories` include it. Anything else is `401`, as
    GitHub answers a clone it will not serve, so a token for one repository clones no other;
  - nothing else: any other path is `404`.

  Every token request is kept (`requests/1`), and every token issued (`tokens/1`), so a
  test can say what was asked for and look for each token where it must not be.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Start one under the test's supervisor. Answers `%{agent, url, api_url}`."
  def start(opts \\ []) do
    agent =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               apps: %{},
               installations: %{},
               repos: %{},
               tokens: %{},
               requests: [],
               ttl: Keyword.get(opts, :ttl, 3600)
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
    url = "http://127.0.0.1:#{port}"
    %{agent: agent, url: url, api_url: url <> "/api/v3", host: "127.0.0.1"}
  end

  @doc "Register an App: its id, and the private key GitHub would hold the public half of."
  def app(fake, app_id, private_key) do
    public = private_key |> JOSE.JWK.from_key() |> JOSE.JWK.to_public()
    Agent.update(fake.agent, &put_in(&1.apps[app_id], public))
  end

  @doc "Install an App on `owner`, for the repositories named."
  def install(fake, installation_id, app_id, owner, repositories) do
    entry = %{app_id: app_id, owner: owner, repositories: repositories}
    Agent.update(fake.agent, &put_in(&1.installations[installation_id], entry))
  end

  @doc "Serve the repository at `path` as `owner/name`."
  def repo(fake, full_name, path) do
    Agent.update(fake.agent, &put_in(&1.repos[String.downcase(full_name)], path))
  end

  @doc "How long a token issued from now lives, in seconds."
  def ttl(fake, seconds), do: Agent.update(fake.agent, &%{&1 | ttl: seconds})

  @doc "Every token request, oldest first: `%{installation_id, iss, repositories, permissions}`."
  def requests(fake), do: fake.agent |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "Every token issued."
  def tokens(fake), do: fake.agent |> Agent.get(& &1.tokens) |> Map.keys()

  @doc "What a token was issued for."
  def token(fake, token), do: Agent.get(fake.agent, &Map.get(&1.tokens, token))

  # -- the server ---------------------------------------------------------------

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(
        %Plug.Conn{
          method: "POST",
          path_info: ["api", "v3", "app", "installations", id, "access_tokens"]
        } =
          conn,
        agent
      ) do
    {:ok, body, conn} = read_body(conn)
    asked = if body == "", do: %{}, else: Jason.decode!(body)

    with {:ok, installation_id} <- integer(id),
         {:ok, installation} <- fetch(agent, :installations, installation_id),
         {:ok, claims} <- verify(conn, agent, installation.app_id),
         {:ok, repositories} <- within(asked["repositories"], installation.repositories),
         {:ok, permissions} <- permissions(asked["permissions"]) do
      token = "ghs_" <> Base.encode32(:crypto.strong_rand_bytes(20), padding: false, case: :lower)
      ttl = Agent.get(agent, & &1.ttl)
      expires_at = System.system_time(:second) + ttl

      Agent.update(agent, fn state ->
        state
        |> put_in([:tokens, token], %{
          installation_id: installation_id,
          owner: installation.owner,
          repositories: repositories,
          permissions: permissions,
          expires_at: expires_at
        })
        |> Map.update!(:requests, fn requests ->
          [
            %{
              installation_id: installation_id,
              iss: claims["iss"],
              repositories: asked["repositories"],
              permissions: asked["permissions"]
            }
            | requests
          ]
        end)
      end)

      answer(conn, 201, %{
        "token" => token,
        "expires_at" => expires_at |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        "permissions" => permissions,
        "repository_selection" => "selected",
        "repositories" =>
          Enum.map(repositories, &%{"name" => &1, "full_name" => "#{installation.owner}/#{&1}"})
      })
    else
      {:error, status, message} -> answer(conn, status, %{"message" => message})
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: [owner, repo, "info", "refs"]} = conn, agent) do
    conn = fetch_query_params(conn)

    with "git-upload-pack" <- conn.query_params["service"],
         {:ok, path} <- authorised(conn, agent, owner, repo) do
      {advertised, 0} =
        System.cmd("git", ["upload-pack", "--stateless-rpc", "--advertise-refs", path])

      conn
      |> put_resp_content_type("application/x-git-upload-pack-advertisement", nil)
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, [pkt("# service=git-upload-pack\n"), "0000", advertised])
    else
      {:error, :unauthorised} -> unauthorised(conn)
      _other -> send_resp(conn, 403, "smart HTTP upload-pack only\n")
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: [owner, repo, "git-upload-pack"]} = conn, agent) do
    case authorised(conn, agent, owner, repo) do
      {:ok, path} ->
        {:ok, body, conn} = read_all(conn, [])

        body =
          if get_req_header(conn, "content-encoding") == ["gzip"],
            do: :zlib.gunzip(body),
            else: body

        request =
          Path.join(System.tmp_dir!(), "fake-github-#{System.unique_integer([:positive])}")

        File.write!(request, body)

        {result, 0} =
          System.cmd("sh", [
            "-c",
            ~S(exec git upload-pack --stateless-rpc "$0" < "$1"),
            path,
            request
          ])

        File.rm(request)

        conn
        |> put_resp_content_type("application/x-git-upload-pack-result", nil)
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, result)

      {:error, :unauthorised} ->
        unauthorised(conn)
    end
  end

  def call(conn, _agent), do: send_resp(conn, 404, "Not Found")

  # -- the App's JWT --------------------------------------------------------------

  defp verify(conn, agent, app_id) do
    with ["Bearer " <> jwt] <- get_req_header(conn, "authorization"),
         {:ok, public} <- fetch(agent, :apps, app_id),
         {true, %JOSE.JWT{fields: claims}, _jws} <- JOSE.JWT.verify_strict(public, ["RS256"], jwt),
         now = System.system_time(:second),
         true <- claims["iss"] in [app_id, to_string(app_id)],
         true <- is_integer(claims["exp"]) and claims["exp"] > now,
         true <- is_integer(claims["iat"]) and claims["iat"] <= now + 60,
         true <- claims["exp"] - claims["iat"] <= 600 do
      {:ok, claims}
    else
      _ -> {:error, 401, "A JSON web token could not be decoded"}
    end
  end

  defp within(nil, _allowed), do: {:error, 422, "a token here is always narrowed to repositories"}

  defp within(asked, allowed) when is_list(asked) do
    if asked != [] and Enum.all?(asked, &(&1 in allowed)),
      do: {:ok, asked},
      else:
        {:error, 422,
         "There is at least one repository that does not exist or is not accessible to the parent installation."}
  end

  defp permissions(%{"contents" => level} = asked) when level in ["read", "write"],
    do: {:ok, asked}

  defp permissions(_asked),
    do: {:error, 422, "The permissions requested are not granted to this installation."}

  # -- a clone ------------------------------------------------------------------

  defp authorised(conn, agent, owner, repo) do
    name = String.replace_suffix(repo, ".git", "")
    state = Agent.get(agent, & &1)

    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, pair} <- Base.decode64(encoded),
         [_username, token] <- String.split(pair, ":", parts: 2),
         %{} = issued <- Map.get(state.tokens, token),
         true <- issued.expires_at > System.system_time(:second),
         true <- String.downcase(issued.owner) == String.downcase(owner),
         true <- name in issued.repositories,
         {:ok, path} <- Map.fetch(state.repos, String.downcase("#{owner}/#{name}")) do
      {:ok, path}
    else
      _ -> {:error, :unauthorised}
    end
  end

  defp unauthorised(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="GitHub"))
    |> send_resp(401, "Invalid username or token.\n")
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_all(conn, [chunk | acc])
    end
  end

  # A pkt-line: four hex digits of length, the four included, then the line.
  defp pkt(line) do
    length = (byte_size(line) + 4) |> Integer.to_string(16) |> String.downcase()
    String.pad_leading(length, 4, "0") <> line
  end

  # -- small things -------------------------------------------------------------

  defp integer(text) do
    case Integer.parse(text) do
      {number, ""} -> {:ok, number}
      _ -> {:error, 404, "Not Found"}
    end
  end

  defp fetch(agent, table, key) do
    case Agent.get(agent, &Map.get(Map.fetch!(&1, table), key)) do
      nil -> {:error, 404, "Not Found"}
      found -> {:ok, found}
    end
  end

  defp answer(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
