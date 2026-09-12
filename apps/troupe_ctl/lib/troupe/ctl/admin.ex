defmodule Troupe.Ctl.Admin do
  @moduledoc """
  `troupe admin` — the third rendering of `Troupe.Plane.Admin`.

  Every command here is one admin JSON-RPC method, reached over the plane's public
  `/rpc` like any other client. That is the Forbidden list's "any client, including our
  own TUI and panel, using anything but public APIs": this binary has no privileged path
  into the plane, and a person with `curl` and a token can do exactly what it can.

  The commands are generated from one table, and `Troupe.Plane.AdminParityTest` asserts
  the table covers every function the context has. A panel button with no command, or a
  command with no button, is a test failure rather than something somebody notices a
  release later.
  """

  alias Troupe.Ctl.{Credentials, Remote}
  alias Troupe.Protocol.AgentDefinition

  @commands [
    {~w(overview), "admin.overview", [], "fleet health, active sessions, spend per team"},
    {~w(profiles), "admin.profiles.list", [], "every profile, with its pods and load"},
    {~w(profile show), "admin.profile.get", ["name"],
     "one profile: spec, policy verdict, bundle state"},
    {~w(profile put), "admin.profile.put", ["file"],
     "create or update a profile from a JSON file"},
    {~w(profile check), "admin.profile.preview", ["file"],
     "what policy makes of a profile, and what would change"},
    {~w(profile delete), "admin.profile.delete", ["name"], "remove a profile"},
    {~w(pod drain), "admin.pod.drain", ["worker_id"], "drain a pod, and say what it held"},
    {~w(teams), "admin.teams.list", [], "teams, with grants, budgets and retention"},
    {~w(team enable), "admin.team.enable", ["group"], "make an identity-provider group a team"},
    {~w(team update), "admin.team.update", ["name", "file"],
     "change budget, retention or visibility"},
    {~w(team grant), "admin.team.grant", ["name", "profile"], "give a team access to a profile"},
    {~w(team revoke), "admin.team.revoke", ["name", "profile"], "take it away"},
    {~w(team admin add), "admin.team.admin.add", ["name", "subject"],
     "make somebody a team admin"},
    {~w(team admin remove), "admin.team.admin.remove", ["name", "subject"], "take the role away"},
    {~w(sessions), "admin.sessions.list", [], "session metadata, never content"},
    {~w(session erase), "admin.session.erase", ["session_id"], "erase a session, irreversibly"},
    {~w(bundles), "admin.bundles.list", ["channel"], "every version of a channel"},
    {~w(bundle show), "admin.bundle.get", ["channel", "version"],
     "one version: document, summary, hash"},
    {~w(bundle validate), "admin.bundle.validate", ["file"],
     "check a bundle without publishing it"},
    {~w(bundle publish), "admin.bundle.publish", ["channel", "file"], "publish a new version"},
    {~w(bundle retire), "admin.bundle.retire", ["channel", "version"], "retire one"},
    {~w(mcp check), "admin.mcp.check", ["url"], "whether policy lets a pod reach an MCP server"},
    {~w(audit), "admin.audit.list", [], "who changed what, newest first"},
    {~w(provisioning), "admin.provisioning.mode", [],
     "whether this plane applies directly or through GitOps"},
    {~w(principal list), "admin.principals.list", ["team"], "a team's service principals"},
    {~w(principal create), "admin.principal.create", ["team", "name", "profiles"],
     "create one; PROFILES is comma-separated, and the secret is printed once"},
    {~w(principal rotate), "admin.principal.rotate", ["subject"],
     "mint a new secret; the old one stops at once"},
    {~w(principal disable), "admin.principal.disable", ["subject"],
     "disable one; its sessions are kept"},
    {~w(trigger list), "admin.triggers.list", ["team"], "a team's triggers"},
    {~w(trigger put), "admin.trigger.put", ["file"],
     "create or update a trigger from a JSON file"},
    {~w(trigger delete), "admin.trigger.delete", ["team", "name"],
     "remove a trigger; its sessions are kept"},
    {~w(trigger run), "admin.trigger.run", ["team", "name"], "fire a trigger now, by hand"},
    {~w(runs), "admin.runs.list", ["team", "trigger?"],
     "a team's runs, newest first, or one trigger's"}
  ]

  @doc "Every command, its method, its arguments and its one-line help."
  @spec commands() :: [{[String.t()], String.t(), [String.t()], String.t()}]
  def commands, do: @commands

  @doc "The methods `troupe admin` can reach."
  @spec methods() :: [String.t()]
  def methods, do: Enum.map(@commands, fn {_words, method, _args, _help} -> method end)

  @doc "Run one `troupe admin` invocation. Returns the process exit code."
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) do
    case match(argv) do
      {:ok, {_words, method, argument_names, _help}, rest} ->
        dispatch(method, argument_names, rest, opts)

      :error ->
        IO.puts(:stderr, usage())
        2
    end
  end

  # Longest match first, so `team admin add` is not read as `team` with three arguments.
  defp match(argv) do
    @commands
    |> Enum.sort_by(fn {words, _method, _args, _help} -> -length(words) end)
    |> Enum.find_value(:error, fn {words, _method, _args, _help} = command ->
      case Enum.split(argv, length(words)) do
        {^words, rest} -> {:ok, command, rest}
        _ -> nil
      end
    end)
  end

  # An argument named with a trailing `?` may be left out; everything before it may not.
  defp dispatch(method, argument_names, given, opts) do
    required = Enum.reject(argument_names, &optional?/1)

    if length(given) < length(required) do
      IO.puts(:stderr, "troupe admin: #{method} needs #{Enum.join(required, ", ")}")
      2
    else
      params =
        argument_names
        |> Enum.map(&String.trim_trailing(&1, "?"))
        |> Enum.zip(given)
        |> Map.new()
        |> resolve_files()
        |> resolve_lists()

      request(method, params, opts)
    end
  end

  defp optional?(name), do: String.ends_with?(name, "?")

  # A `file` argument is JSON on disk. A profile or a config bundle is too big to be a
  # command line, and one edited in a file is one that can be kept in a repository. A
  # *directory* is a config bundle laid out the way one lives in a repository, and is
  # assembled into the document here — see `bundle_from_directory/1`.
  defp resolve_files(params) do
    case Map.pop(params, "file") do
      {nil, params} -> params
      {path, params} -> merge_file(params, path)
    end
  end

  # A directory is assembled into the one document; a file is the document, decoded.
  defp merge_file(params, path) do
    if File.dir?(path),
      do: Map.put(params, "content", bundle_from_directory(path)),
      else: Map.merge(params, decode_file(read!(path)))
  end

  # The one object a file holds, under every name a method might take it by. The plane
  # reads the one it wants and ignores the rest.
  defp decode_file(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = decoded} ->
        %{"profile" => decoded, "attrs" => decoded, "content" => decoded, "trigger" => decoded}

      _ ->
        throw({:admin, "that file is not a JSON object"})
    end
  end

  # A list on a command line is comma-separated: `dev,review`.
  defp resolve_lists(params) do
    case Map.fetch(params, "profiles") do
      {:ok, text} when is_binary(text) ->
        Map.put(params, "profiles", String.split(text, ",", trim: true))

      _ ->
        params
    end
  end

  @doc """
  The bundle document a directory describes.

      agents/<name>.md          one agent definition each; the name is the file's
      skills/<name>/SKILL.md    a skill, with whatever files sit beside it
      mcp.yaml | mcp.json       a list of MCP servers

  This is how a bundle lives in git: the same files the worker materialises, in the same
  layout, so publishing a directory and publishing the panel's JSON of the same content
  produce the same hash. A skill's description is read from its `SKILL.md` frontmatter
  rather than asked for twice. Nothing is validated here — the plane does that, once,
  with the same code for every client — but a directory with none of the three parts is
  refused, because it is almost certainly the wrong path.
  """
  @spec bundle_from_directory(Path.t()) :: map()
  def bundle_from_directory(dir) do
    agents = agents_in(dir)
    skills = skills_in(dir)
    servers = servers_in(dir)

    if agents == [] and skills == [] and servers == [] and not has_mcp_file?(dir) do
      throw({:admin, "#{dir} has no agents/, skills/ or mcp.yaml; is it a bundle directory?"})
    end

    %{"schema" => 1, "agents" => agents, "skills" => skills, "mcp_servers" => servers}
  end

  defp agents_in(dir) do
    dir
    |> Path.join("agents/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      %{"name" => Path.basename(path, ".md"), "definition" => read!(path)}
    end)
  end

  defp skills_in(dir) do
    dir
    |> Path.join("skills/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
    |> Enum.map(fn skill_dir ->
      files =
        skill_dir
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Map.new(fn path -> {Path.relative_to(path, skill_dir), read!(path)} end)

      %{
        "name" => Path.basename(skill_dir),
        "description" => description_of(files["SKILL.md"]),
        "files" => files
      }
    end)
  end

  defp description_of(nil), do: ""

  defp description_of(manifest) do
    {frontmatter, _body} = AgentDefinition.split_frontmatter(manifest)

    case YamlElixir.read_from_string(frontmatter) do
      {:ok, %{"description" => description}} when is_binary(description) -> description
      _ -> ""
    end
  end

  # A list of servers, or an object with the list under `mcp_servers` — the second so a
  # file copied out of a bundle document works unchanged.
  defp servers_in(dir) do
    yaml = Path.join(dir, "mcp.yaml")
    json = Path.join(dir, "mcp.json")

    cond do
      File.regular?(yaml) -> yaml |> read_yaml() |> server_list()
      File.regular?(json) -> json |> read_json() |> server_list()
      true -> []
    end
  end

  defp has_mcp_file?(dir) do
    File.regular?(Path.join(dir, "mcp.yaml")) or File.regular?(Path.join(dir, "mcp.json"))
  end

  defp server_list(list) when is_list(list), do: list
  defp server_list(%{"mcp_servers" => list}) when is_list(list), do: list
  defp server_list(_other), do: throw({:admin, "mcp.yaml is a list of servers"})

  defp read_yaml(path) do
    case YamlElixir.read_from_string(read!(path)) do
      {:ok, decoded} -> decoded
      {:error, reason} -> throw({:admin, "could not read #{path}: #{inspect(reason)}"})
    end
  end

  defp read_json(path) do
    case Jason.decode(read!(path)) do
      {:ok, decoded} -> decoded
      {:error, reason} -> throw({:admin, "could not read #{path}: #{Exception.message(reason)}"})
    end
  end

  defp read!(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, reason} -> throw({:admin, "could not read #{path}: #{:file.format_error(reason)}"})
    end
  end

  defp request(method, params, opts) do
    with {:ok, plane, token} <- credentials(opts),
         {:ok, result} <- call(plane, token, method, params) do
      IO.puts(Jason.encode!(result, pretty: true))
      0
    else
      {:error, message} ->
        IO.puts(:stderr, "troupe admin: #{message}")
        1
    end
  end

  defp credentials(opts) do
    case Keyword.get(opts, :credentials) || Credentials.default() do
      nil ->
        {:error, "not logged in to any plane — run `troupe login <plane-url>`"}

      %{"plane" => plane} = stored ->
        case Keyword.get(opts, :token) || refresh(stored) do
          {:ok, token} -> {:ok, plane, token}
          {:error, reason} -> {:error, reason}
          token when is_binary(token) -> {:ok, plane, token}
        end
    end
  end

  # One implementation of "turn the stored refresh token into a plane token", shared with
  # `troupe --remote`. There used to be two, and both had the same bug: a provider that
  # rotates refresh tokens — which is most of them — invalidated the stored one on first
  # use, so everything worked once and then asked you to log in again.
  defp refresh(%{"plane" => plane} = stored) do
    case Remote.session_token(stored) do
      {:ok, token} ->
        {:ok, token}

      {:error, _reason} ->
        {:error, "could not renew the session for #{plane} — run `troupe login #{plane}` again"}
    end
  end

  defp call(plane, token, method, params) do
    options = [
      method: :post,
      url: plane <> "/rpc",
      json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      headers: [{"authorization", "Bearer " <> token}],
      decode_body: true,
      retry: false
    ]

    case Req.request(options) do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{status: 200, body: %{"error" => error}}} -> {:error, describe(error)}
      {:ok, %{status: status}} -> {:error, "the plane answered #{status}"}
      {:error, reason} -> {:error, "could not reach #{plane}: #{inspect(reason)}"}
    end
  end

  defp describe(%{"message" => message, "data" => data}) when data not in [nil, %{}] do
    "#{message} (#{Jason.encode!(data)})"
  end

  defp describe(%{"message" => message}), do: message
  defp describe(error), do: inspect(error)

  @doc "The help `troupe admin` prints with no arguments."
  @spec usage() :: String.t()
  def usage do
    widest =
      @commands |> Enum.map(fn {words, _m, args, _h} -> width(words, args) end) |> Enum.max()

    lines =
      Enum.map_join(@commands, "\n", fn {words, _method, args, help} ->
        "  troupe admin " <> String.pad_trailing(invocation(words, args), widest) <> "  " <> help
      end)

    """
    troupe admin — administer a Troupe plane

    Every command is one call to the plane's public API, with the token
    `troupe login` stored. There is no privileged path: a person with curl can do
    exactly what this can.

    #{lines}

    Arguments named FILE are paths to a JSON object. For a bundle, FILE may be a
    directory laid out as agents/*.md, skills/<name>/SKILL.md and mcp.yaml. For a
    trigger it is the definition: team, name, principal, profile, source,
    prompt_template, terms, visibility, review, notify, concurrency, enabled.
    Arguments in [brackets] may be left out.
    """
  end

  defp invocation(words, args) do
    Enum.join(words ++ Enum.map(args, &argument_name/1), " ")
  end

  defp argument_name(name) do
    if optional?(name),
      do: "[" <> String.upcase(String.trim_trailing(name, "?")) <> "]",
      else: String.upcase(name)
  end

  defp width(words, args), do: words |> invocation(args) |> String.length()

  @doc false
  @spec safe([String.t()], keyword()) :: non_neg_integer()
  def safe(argv, opts \\ []) do
    run(argv, opts)
  catch
    {:admin, message} ->
      IO.puts(:stderr, "troupe admin: #{message}")
      2
  end
end
