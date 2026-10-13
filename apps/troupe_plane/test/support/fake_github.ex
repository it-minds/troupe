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
  - **the REST calls the fix loop makes** (`/api/v3/repos/<owner>/<name>/...`), for a token
    of that repository sent as `Bearer` and holding the permission each needs, else `403`
    as GitHub answers ("Resource not accessible by integration"): the repository, blobs,
    trees, commits and branch refs of the Git data API, written into the test repository
    with the real git (a commit made through it is the App's bot's, and verified, as
    GitHub makes an App's); draft and ready pull requests; comments on them; and the
    commit's check runs and combined status, which the test scripts (`ci/3`). A ruleset
    (`ruleset/3`) refuses a branch write outside a prefix, as one keyed on the App would;
  - nothing else: any other path is `404`.

  Every token request is kept (`requests/1`), every token issued (`tokens/1`) and every
  write the API was asked for (`writes/1`), merges and reviews included, which nothing is
  ever let do; so a test can say what was asked for and look for each token where it must
  not be.
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
               slugs: %{},
               installations: %{},
               repos: %{},
               tokens: %{},
               requests: [],
               ttl: Keyword.get(opts, :ttl, 3600),
               # The fix loop's side of GitHub: pull requests and comments by repository,
               # every write asked for, the CI each pushed head gets, and rulesets.
               pulls: %{},
               comments: [],
               writes: [],
               ci: %{},
               checks: %{},
               rulesets: %{}
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

  @doc """
  Register an App: its id, and the private key GitHub would hold the public half of.
  `slug:` is the App's name in URLs, whose bot user its commits are made as.
  """
  def app(fake, app_id, private_key, opts \\ []) do
    public = private_key |> JOSE.JWK.from_key() |> JOSE.JWK.to_public()

    Agent.update(fake.agent, fn state ->
      state
      |> put_in([:apps, app_id], public)
      |> put_in([:slugs, app_id], Keyword.get(opts, :slug, "troupe-test"))
    end)
  end

  @doc """
  The CI each head pushed to `full_name` gets, in order: the first push's head the first
  entry, and so on; a push past the end gets none. An entry is a list of check runs, each
  `%{"name", "status", "conclusion", "output" => %{"title", "summary", "text"}}`, or
  `%{checks: [...], statuses: [%{"context", "state", "description"}]}`.
  """
  def ci(fake, full_name, entries),
    do: Agent.update(fake.agent, &put_in(&1.ci[String.downcase(full_name)], entries))

  @doc "Set the check runs of one commit, as CI finishing or changing its mind would."
  def checks(fake, sha, entry), do: Agent.update(fake.agent, &put_in(&1.checks[sha], entry))

  @doc "A ruleset on `full_name` that lets the App write only branches under `prefix`."
  def ruleset(fake, full_name, prefix),
    do: Agent.update(fake.agent, &put_in(&1.rulesets[String.downcase(full_name)], prefix))

  @doc "Every API write, oldest first: `%{method, path, body}`."
  def writes(fake), do: fake.agent |> Agent.get(& &1.writes) |> Enum.reverse()

  @doc "The pull requests of `full_name`, by number."
  def pulls(fake, full_name),
    do: Agent.get(fake.agent, &Map.get(&1.pulls, String.downcase(full_name), %{}))

  @doc "Every comment, oldest first: `%{repository, number, body}`."
  def comments(fake), do: fake.agent |> Agent.get(& &1.comments) |> Enum.reverse()

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

  def call(%Plug.Conn{path_info: ["api", "v3", "repos", owner, name | rest]} = conn, agent) do
    {:ok, body, conn} = read_all(conn, [])
    asked = if body == "", do: %{}, else: Jason.decode!(body)
    full = String.downcase("#{owner}/#{name}")

    if conn.method != "GET" do
      write = %{method: conn.method, path: Enum.join(rest, "/"), body: asked}
      Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [write | writes] end))
    end

    with {:ok, path} <- repository_path(agent, full),
         {:ok, issued} <- api_token(conn, agent, owner, name),
         :ok <- allowed(issued, needs(conn.method, rest)) do
      api(conn.method, rest, asked, %{
        agent: agent,
        conn: conn,
        path: path,
        owner: owner,
        name: name,
        full: full,
        issued: issued
      })
    else
      {:error, status, message} -> answer(conn, status, %{"message" => message})
    end
  end

  def call(conn, _agent), do: send_resp(conn, 404, "Not Found")

  # -- the fix loop's REST calls ---------------------------------------------------

  # What each call needs of the token, as GitHub's fine-grained permissions table has it.
  defp needs("GET", []), do: %{}
  defp needs(_method, ["git" | _]), do: %{"contents" => "write"}
  defp needs("GET", ["pulls" | _]), do: %{"pull_requests" => "read"}
  defp needs(_method, ["pulls" | _]), do: %{"pull_requests" => "write"}
  defp needs(_method, ["issues", _number, "comments"]), do: %{"pull_requests" => "write"}
  defp needs("GET", ["commits", _sha, "check-runs"]), do: %{"checks" => "read"}
  defp needs("GET", ["commits", _sha, "status"]), do: %{"statuses" => "read"}
  defp needs(_method, _rest), do: %{"administration" => "write"}

  defp allowed(issued, needs) do
    if Enum.all?(needs, fn {name, level} -> at_least?(issued.permissions[name], level) end),
      do: :ok,
      else: {:error, 403, "Resource not accessible by integration"}
  end

  defp at_least?("write", _level), do: true
  defp at_least?("read", "read"), do: true
  defp at_least?(_held, _level), do: false

  defp api("GET", [], _asked, ctx) do
    {branch, 0} = git(ctx.path, ["symbolic-ref", "--short", "HEAD"])

    answer(ctx.conn, 200, %{
      "full_name" => "#{ctx.owner}/#{ctx.name}",
      "default_branch" => String.trim(branch),
      "html_url" => "#{base_url(ctx.conn)}/#{ctx.owner}/#{ctx.name}"
    })
  end

  defp api("POST", ["git", "blobs"], %{"content" => content, "encoding" => "base64"}, ctx) do
    file = temporary(Base.decode64!(content, ignore: :whitespace))
    {sha, 0} = git(ctx.path, ["hash-object", "-w", "--no-filters", file])
    File.rm(file)
    answer(ctx.conn, 201, %{"sha" => String.trim(sha)})
  end

  defp api("POST", ["git", "trees"], %{"tree" => entries} = asked, ctx) do
    index =
      Path.join(System.tmp_dir!(), "fake-github-index-#{System.unique_integer([:positive])}")

    env = [{"GIT_INDEX_FILE", index}]

    if base = asked["base_tree"], do: {_, 0} = git(ctx.path, ["read-tree", base], env)

    result =
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case tree_entry(ctx.path, entry, env) do
          :ok -> {:cont, :ok}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)

    case result do
      :ok ->
        {tree, 0} = git(ctx.path, ["write-tree"], env)
        File.rm(index)
        answer(ctx.conn, 201, %{"sha" => String.trim(tree)})

      {:error, message} ->
        File.rm(index)
        answer(ctx.conn, 422, %{"message" => message})
    end
  end

  defp api("POST", ["git", "commits"], %{"tree" => tree, "message" => message} = asked, ctx) do
    parents = asked["parents"] || []

    if Enum.all?(parents, &exists?(ctx.path, &1 <> "^{commit}")) and
         exists?(ctx.path, tree <> "^{tree}") do
      bot = bot(ctx.agent, ctx.issued)
      file = temporary(message)

      env = [
        {"GIT_AUTHOR_NAME", bot.name},
        {"GIT_AUTHOR_EMAIL", bot.email},
        {"GIT_COMMITTER_NAME", bot.name},
        {"GIT_COMMITTER_EMAIL", bot.email}
      ]

      {sha, 0} =
        git(
          ctx.path,
          ["commit-tree", tree] ++ Enum.flat_map(parents, &["-p", &1]) ++ ["-F", file],
          env
        )

      File.rm(file)
      sha = String.trim(sha)

      answer(ctx.conn, 201, %{
        "sha" => sha,
        "tree" => %{"sha" => tree},
        "author" => %{"name" => bot.name, "email" => bot.email},
        "html_url" => "#{base_url(ctx.conn)}/#{ctx.owner}/#{ctx.name}/commit/#{sha}",
        # An App's commit made through the API, with no author or signature given, is
        # signed by GitHub; one that names its own is not.
        "verification" => %{
          "verified" => not Enum.any?(~w(author committer signature), &Map.has_key?(asked, &1)),
          "reason" => "valid"
        }
      })
    else
      answer(ctx.conn, 422, %{"message" => "Parent SHA does not exist or is not a commit object"})
    end
  end

  defp api("GET", ["git", "commits", sha], _asked, ctx) do
    with {raw, 0} <- git(ctx.path, ["cat-file", "commit", sha]),
         [head, message] <- String.split(raw, "\n\n", parts: 2) do
      lines = String.split(head, "\n")

      answer(ctx.conn, 200, %{
        "sha" => sha,
        "tree" => %{"sha" => hd(header(lines, "tree"))},
        "parents" => Enum.map(header(lines, "parent"), &%{"sha" => &1}),
        "message" => message
      })
    else
      _none -> answer(ctx.conn, 404, %{"message" => "Not Found"})
    end
  end

  defp api("GET", ["git", "ref", "heads" | branch], _asked, ctx) do
    ref = "refs/heads/" <> Enum.join(branch, "/")

    case git(ctx.path, ["rev-parse", "--verify", "--quiet", ref]) do
      {sha, 0} ->
        answer(ctx.conn, 200, %{
          "ref" => ref,
          "object" => %{"sha" => String.trim(sha), "type" => "commit"}
        })

      _none ->
        answer(ctx.conn, 404, %{"message" => "Not Found"})
    end
  end

  defp api("POST", ["git", "refs"], %{"ref" => "refs/heads/" <> branch = ref, "sha" => sha}, ctx) do
    ruled(ctx, branch, fn ->
      case git(ctx.path, ["update-ref", ref, sha, String.duplicate("0", 40)]) do
        {_, 0} ->
          pushed(ctx, sha)
          answer(ctx.conn, 201, %{"ref" => ref, "object" => %{"sha" => sha}})

        _exists ->
          answer(ctx.conn, 422, %{"message" => "Reference already exists"})
      end
    end)
  end

  defp api("PATCH", ["git", "refs", "heads" | branch], %{"sha" => sha} = asked, ctx) do
    branch = Enum.join(branch, "/")
    ref = "refs/heads/" <> branch

    ruled(ctx, branch, fn ->
      case git(ctx.path, ["rev-parse", "--verify", "--quiet", ref]) do
        {old, 0} -> advance(ctx, ref, String.trim(old), sha, asked["force"] == true)
        _none -> answer(ctx.conn, 422, %{"message" => "Reference does not exist"})
      end
    end)
  end

  defp api("POST", ["pulls"], %{"head" => head, "base" => base} = asked, ctx) do
    open = pulls_of(ctx.agent, ctx.full)

    cond do
      not exists?(ctx.path, "refs/heads/" <> head) or not exists?(ctx.path, "refs/heads/" <> base) ->
        answer(ctx.conn, 422, %{
          "message" => "Validation Failed",
          "errors" => [%{"field" => "head"}]
        })

      Enum.any?(open, fn {_n, pull} -> pull["head"]["ref"] == head end) ->
        answer(ctx.conn, 422, %{
          "message" => "A pull request already exists for #{ctx.owner}:#{head}."
        })

      true ->
        number = map_size(open) + 1
        {sha, 0} = git(ctx.path, ["rev-parse", "refs/heads/" <> head])

        pull = %{
          "number" => number,
          "html_url" => "#{base_url(ctx.conn)}/#{ctx.owner}/#{ctx.name}/pull/#{number}",
          "state" => "open",
          "draft" => asked["draft"] == true,
          "title" => asked["title"],
          "body" => asked["body"],
          "head" => %{"ref" => head, "sha" => String.trim(sha)},
          "base" => %{"ref" => base},
          "merged" => false
        }

        Agent.update(ctx.agent, &put_in(&1.pulls[ctx.full], Map.put(open, number, pull)))
        answer(ctx.conn, 201, pull)
    end
  end

  defp api("GET", ["pulls", number], _asked, ctx) do
    case Map.get(pulls_of(ctx.agent, ctx.full), String.to_integer(number)) do
      nil -> answer(ctx.conn, 404, %{"message" => "Not Found"})
      pull -> answer(ctx.conn, 200, pull)
    end
  end

  defp api("POST", ["issues", number, "comments"], %{"body" => body}, ctx) do
    number = String.to_integer(number)

    if Map.has_key?(pulls_of(ctx.agent, ctx.full), number) do
      id = System.unique_integer([:positive])
      comment = %{repository: ctx.full, number: number, body: body}
      Agent.update(ctx.agent, &Map.update!(&1, :comments, fn all -> [comment | all] end))

      answer(ctx.conn, 201, %{
        "id" => id,
        "html_url" =>
          "#{base_url(ctx.conn)}/#{ctx.owner}/#{ctx.name}/pull/#{number}#issuecomment-#{id}"
      })
    else
      answer(ctx.conn, 404, %{"message" => "Not Found"})
    end
  end

  defp api("GET", ["commits", sha, "check-runs"], _asked, ctx) do
    runs = ctx.agent |> ci_of(sha) |> runs_of()
    answer(ctx.conn, 200, %{"total_count" => length(runs), "check_runs" => runs})
  end

  defp api("GET", ["commits", sha, "status"], _asked, ctx) do
    statuses = ctx.agent |> ci_of(sha) |> statuses_of()

    state =
      cond do
        Enum.any?(statuses, &(&1["state"] in ["failure", "error"])) -> "failure"
        statuses != [] and Enum.all?(statuses, &(&1["state"] == "success")) -> "success"
        true -> "pending"
      end

    answer(ctx.conn, 200, %{
      "state" => state,
      "total_count" => length(statuses),
      "statuses" => statuses
    })
  end

  # Merging, approving, deleting a branch: nothing in the fix loop asks for them, and
  # the write is kept (`writes/1`) for the test that says so.
  defp api(_method, _rest, _asked, ctx),
    do: answer(ctx.conn, 403, %{"message" => "Resource not accessible by integration"})

  # A branch moves forward unless the request forces it, as GitHub's refs API does.
  defp advance(ctx, ref, old, sha, force?) do
    if force? or match?({_, 0}, git(ctx.path, ["merge-base", "--is-ancestor", old, sha])) do
      {_, 0} = git(ctx.path, ["update-ref", ref, sha, old])
      pushed(ctx, sha)
      answer(ctx.conn, 200, %{"ref" => ref, "object" => %{"sha" => sha}})
    else
      answer(ctx.conn, 422, %{"message" => "Update is not a fast forward"})
    end
  end

  defp tree_entry(path, %{"path" => file, "sha" => nil}, env) do
    {_, _} = git(path, ["update-index", "--force-remove", "--", file], env)
    :ok
  end

  defp tree_entry(path, %{"path" => file, "mode" => mode, "sha" => sha} = entry, env) do
    kind = if entry["type"] == "commit", do: "commit", else: "blob"

    if kind == "commit" or exists?(path, sha <> "^{blob}") do
      {_, 0} = git(path, ["update-index", "--add", "--cacheinfo", "#{mode},#{sha},#{file}"], env)
      :ok
    else
      {:error, "tree.sha #{sha} is not a valid blob"}
    end
  end

  defp tree_entry(_path, _entry, _env), do: {:error, "tree entries need a path, a mode and a sha"}

  defp ruled(ctx, branch, then) do
    prefix = Agent.get(ctx.agent, &Map.get(&1.rulesets, ctx.full))

    if is_nil(prefix) or String.starts_with?(branch, prefix),
      do: then.(),
      else: answer(ctx.conn, 422, %{"message" => "Repository rule violations found"})
  end

  # A pushed head gets the next CI entry scripted for its repository.
  defp pushed(ctx, sha) do
    Agent.update(ctx.agent, fn state ->
      case Map.get(state.ci, ctx.full, []) do
        [entry | rest] -> state |> put_in([:ci, ctx.full], rest) |> put_in([:checks, sha], entry)
        [] -> state
      end
    end)
  end

  defp ci_of(agent, sha), do: Agent.get(agent, &Map.get(&1.checks, sha))

  defp runs_of(nil), do: []
  defp runs_of(%{checks: runs}), do: runs
  defp runs_of(%{} = _statuses_only), do: []
  defp runs_of(runs) when is_list(runs), do: runs

  defp statuses_of(%{statuses: statuses}), do: statuses
  defp statuses_of(_entry), do: []

  defp pulls_of(agent, full), do: Agent.get(agent, &Map.get(&1.pulls, full, %{}))

  defp bot(agent, issued) do
    slug =
      Agent.get(agent, fn state ->
        app_id = state.installations[issued.installation_id].app_id
        get_in(state, [:slugs, app_id]) || "troupe-test"
      end)

    %{name: "#{slug}[bot]", email: "41898282+#{slug}[bot]@users.noreply.github.com"}
  end

  defp repository_path(agent, full) do
    case Agent.get(agent, &Map.get(&1.repos, full)) do
      nil -> {:error, 404, "Not Found"}
      path -> {:ok, path}
    end
  end

  defp api_token(conn, agent, owner, name) do
    state = Agent.get(agent, & &1)

    with [header] <- get_req_header(conn, "authorization"),
         [_scheme, token] <- String.split(header, " ", parts: 2),
         %{} = issued <- Map.get(state.tokens, token),
         true <- issued.expires_at > System.system_time(:second),
         true <- String.downcase(issued.owner) == String.downcase(owner),
         true <- name in issued.repositories do
      {:ok, issued}
    else
      _ -> {:error, 401, "Bad credentials"}
    end
  end

  defp exists?(path, object), do: match?({_, 0}, git(path, ["cat-file", "-e", object]))

  defp git(path, args, env \\ []),
    do: System.cmd("git", args, cd: path, env: env, stderr_to_stdout: true)

  defp temporary(content) do
    file = Path.join(System.tmp_dir!(), "fake-github-#{System.unique_integer([:positive])}")
    File.write!(file, content)
    file
  end

  defp base_url(conn), do: "http://#{conn.host}:#{conn.port}"

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

  # What the test's App is granted: everything the fix loop may be given, and no more, so a
  # token asked for anything else is refused as GitHub refuses one beyond the App's.
  @granted %{
    "contents" => ["read", "write"],
    "pull_requests" => ["read", "write"],
    "checks" => ["read"],
    "statuses" => ["read"]
  }

  defp permissions(%{} = asked) when map_size(asked) > 0 do
    if Enum.all?(asked, fn {name, level} -> level in Map.get(@granted, name, []) end),
      do: {:ok, asked},
      else: {:error, 422, "The permissions requested are not granted to this installation."}
  end

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

  # The values of one header of a raw commit: `tree <sha>`, `parent <sha>`.
  defp header(lines, name) do
    for line <- lines,
        String.starts_with?(line, name <> " "),
        do: String.replace_prefix(line, name <> " ", "")
  end

  defp answer(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
