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

  alias Troupe.Ctl.Credentials

  @commands [
    {~w(overview), "admin.overview", [], "fleet health, active sessions, spend per team"},
    {~w(profiles), "admin.profiles.list", [], "every profile, with its pods and load"},
    {~w(profile show), "admin.profile.get", ["name"], "one profile: spec, policy verdict, bundle state"},
    {~w(profile put), "admin.profile.put", ["file"], "create or update a profile from a JSON file"},
    {~w(profile delete), "admin.profile.delete", ["name"], "remove a profile"},
    {~w(pod drain), "admin.pod.drain", ["worker_id"], "drain a pod, and say what it held"},
    {~w(teams), "admin.teams.list", [], "teams, with grants, budgets and retention"},
    {~w(team enable), "admin.team.enable", ["group"], "make an identity-provider group a team"},
    {~w(team update), "admin.team.update", ["name", "file"], "change budget, retention or visibility"},
    {~w(team grant), "admin.team.grant", ["name", "profile"], "give a team access to a profile"},
    {~w(team revoke), "admin.team.revoke", ["name", "profile"], "take it away"},
    {~w(team admin add), "admin.team.admin.add", ["name", "subject"], "make somebody a team admin"},
    {~w(team admin remove), "admin.team.admin.remove", ["name", "subject"], "take the role away"},
    {~w(sessions), "admin.sessions.list", [], "session metadata, never content"},
    {~w(session erase), "admin.session.erase", ["session_id"], "erase a session, irreversibly"},
    {~w(bundles), "admin.bundles.list", ["channel"], "every version of a channel"},
    {~w(bundle publish), "admin.bundle.publish", ["channel", "file"], "publish a new version"},
    {~w(bundle retire), "admin.bundle.retire", ["channel", "version"], "retire one"},
    {~w(audit), "admin.audit.list", [], "who changed what, newest first"}
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

  defp dispatch(method, argument_names, given, opts) do
    if length(given) < length(argument_names) do
      IO.puts(:stderr, "troupe admin: #{method} needs #{Enum.join(argument_names, ", ")}")
      2
    else
      params = argument_names |> Enum.zip(given) |> Map.new() |> resolve_files()
      request(method, params, opts)
    end
  end

  # A `file` argument is JSON on disk. A profile or a config bundle is too big to be a
  # command line, and one edited in a file is one that can be kept in a repository.
  defp resolve_files(params) do
    case Map.pop(params, "file") do
      {nil, params} ->
        params

      {path, params} ->
        case File.read(path) do
          {:ok, contents} -> Map.merge(params, decode_file(contents))
          {:error, reason} -> throw({:admin, "could not read #{path}: #{:file.format_error(reason)}"})
        end
    end
  end

  defp decode_file(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = decoded} -> %{"profile" => decoded, "attrs" => decoded, "content" => decoded}
      _ -> throw({:admin, "that file is not a JSON object"})
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

  # A session token is minted from the stored refresh token rather than kept: short,
  # audience-bound, and nothing to leave on disk.
  defp refresh(%{"plane" => plane} = stored) do
    with {:ok, provider_token} <- exchange_refresh(stored),
         {:ok, %{status: 200, body: body}} <-
           Req.request(
             method: :post,
             url: plane <> "/auth/exchange",
             json: %{"id_token" => provider_token},
             decode_body: true,
             retry: false
           ) do
      {:ok, body["token"]}
    else
      _other -> {:error, "could not renew the session for #{plane} — run `troupe login #{plane}` again"}
    end
  end

  defp exchange_refresh(%{"token_endpoint" => endpoint, "client_id" => client, "refresh_token" => refresh})
       when is_binary(endpoint) and is_binary(refresh) do
    options = [
      method: :post,
      url: endpoint,
      form: %{"grant_type" => "refresh_token", "refresh_token" => refresh, "client_id" => client},
      decode_body: true,
      retry: false
    ]

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body["id_token"] || body["access_token"]}

      other ->
        {:error, other}
    end
  end

  defp exchange_refresh(_stored), do: {:error, :no_refresh_token}

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
    widest = @commands |> Enum.map(fn {words, _m, args, _h} -> width(words, args) end) |> Enum.max()

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

    Arguments named FILE are paths to a JSON object.
    """
  end

  defp invocation(words, args) do
    Enum.join(words ++ Enum.map(args, &String.upcase/1), " ")
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
