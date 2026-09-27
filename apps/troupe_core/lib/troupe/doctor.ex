defmodule Troupe.Doctor do
  @moduledoc """
  `troupe doctor` and `troupe-daemon doctor`: one line per check, and an exit status
  that says whether this machine can run a session (Decision 705).

  Each check is a name, a state and one line of detail. `ok` and `warn` let the run
  pass; `fail` does not, and the line says what to do. The checks, in order:

    * `config` — the config files load, and which user file is in force.
    * `provider` — the default model's provider has a key, or needs none
      (`Troupe.Config.key_problem/1`).
    * `key` — the key is accepted: a real request to the provider, the model listing
      (`Troupe.Setup.check_key/1`). A provider that answers but will not list is a
      warning, not a failure; the `fake` provider asks nobody.
    * `key storage` — where the key is kept: the user's `config.yaml`, there being no
      keychain in this build.
    * `daemon` — whether one is answering, and where; not running is not a failure,
      since a client starts one.
    * `troupe-daemon on PATH`, `troupe on PATH` — a warning when missing, with what
      that means.
    * `plane <url>` — for every plane the caller names, and the one the daemon is
      linked to: its discovery document answers.

  Both programs print the same lines; the one difference is which command a line names
  as the next step, `troupe config` through `troupe` and the file through the daemon.
  """

  alias Troupe.Config
  alias Troupe.Protocol.{Daemon, Endpoint}

  @type state :: :ok | :warn | :fail
  @type check :: %{name: String.t(), state: state(), detail: String.t()}

  @doc """
  Run every check.

  Options: `:workspace` (the current directory); `:planes`, URLs the caller knows of
  (the TUI's logins), joined with the daemon's linked plane; `:command`, the program
  printing the answer (`"troupe-daemon"` unless it says `"troupe"`); `:live`, `false`
  to skip the request to the provider and the planes.
  """
  @spec run(keyword()) :: [check()]
  def run(opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || File.cwd!()
    command = Keyword.get(opts, :command, "troupe-daemon")
    live? = Keyword.get(opts, :live, true)
    resolved = Config.resolve(workspace)

    [
      config_check(resolved),
      provider_check(resolved, command),
      key_check(resolved, live?),
      storage_check(),
      daemon_check(),
      path_check("troupe-daemon", "a client starts the daemon from the PATH; troupe embeds one"),
      path_check(
        "troupe",
        "the terminal client; the desktop app and troupe-daemon work without it"
      )
    ] ++ plane_checks(opts, live?)
  end

  @doc "One line per check, as both programs print them."
  @spec format([check()]) :: String.t()
  def format(checks) do
    Enum.map_join(checks, "", fn check ->
      String.pad_trailing(label(check.state), 6) <>
        String.pad_trailing(check.name, 22) <> check.detail <> "\n"
    end)
  end

  @doc "1 when any check failed, else 0."
  @spec exit_status([check()]) :: 0 | 1
  def exit_status(checks), do: if(Enum.any?(checks, &(&1.state == :fail)), do: 1, else: 0)

  defp label(:ok), do: "ok"
  defp label(:warn), do: "warn"
  defp label(:fail), do: "FAIL"

  # -- the checks -----------------------------------------------------------------

  defp config_check({:ok, %Config{warnings: warnings}, _layers}) do
    path = Troupe.Paths.display(Config.user_path())
    file = if File.regular?(Config.user_path()), do: path, else: "no #{path}; the defaults apply"

    case warnings do
      [] ->
        check("config", :ok, file)

      [_ | _] ->
        check(
          "config",
          :warn,
          "#{file}; #{length(warnings)} warning(s); `config validate` lists them"
        )
    end
  end

  defp config_check({:error, error}), do: check("config", :fail, Exception.message(error))

  defp provider_check({:error, _error}, _command),
    do: check("provider", :fail, "not checked: the config files do not load")

  defp provider_check({:ok, config, _layers}, command) do
    model = Config.resolve_model(config, :default)

    case Config.key_problem(config) do
      nil ->
        check("provider", :ok, "#{provider_name(config)}, #{model}, #{key_words(config)}")

      {:no_key, name} ->
        check(
          "provider",
          :fail,
          "#{name} has no key, so no model can be asked; #{next_step(command)}"
        )

      {:refused, why} ->
        check("provider", :fail, why)
    end
  end

  defp key_check({:error, _error}, _live?),
    do: check("key", :fail, "not checked: the config files do not load")

  defp key_check({:ok, config, _layers}, live?) do
    target = Config.target(config, nil)

    cond do
      Config.key_problem(config) != nil ->
        check("key", :fail, "not checked: no key")

      target.provider == "fake" ->
        check("key", :ok, "the fake provider asks nobody")

      not live? ->
        check("key", :ok, "not tried")

      true ->
        target
        |> key_params()
        |> Troupe.Setup.check_key()
        |> key_result(target)
    end
  end

  # The vendor's variable stands in for a key at the vendor's own endpoint, as it does
  # in a request.
  defp key_params(target) do
    key =
      case target.api_key do
        key when is_binary(key) and key != "" ->
          key

        _none ->
          target.provider
          |> Config.vendor_key_var(target.base_url)
          |> then(&(&1 && System.get_env(&1)))
      end

    %{
      "provider" => target.provider,
      "base_url" => target.base_url,
      "api_key" => key,
      "auth" => Atom.to_string(target.auth)
    }
  end

  defp key_result({:ok, models}, target),
    do: check("key", :ok, "accepted by #{target.provider}; #{length(models)} models listed")

  defp key_result({:refused, reason}, target),
    do: check("key", :fail, "refused by #{target.provider}: #{reason}")

  defp key_result({:unknown, reason}, target),
    do:
      check(
        "key",
        :warn,
        "not confirmed: #{target.provider} would not list its models (#{reason})"
      )

  defp storage_check do
    check(
      "key storage",
      :ok,
      "#{Troupe.Paths.display(Config.user_path())}; there is no OS keychain in this build"
    )
  end

  defp daemon_check do
    with {:ok, endpoint} <- Endpoint.discover(),
         true <- Daemon.running?(endpoint: endpoint) do
      check("daemon", :ok, "running at #{Endpoint.describe(endpoint)}")
    else
      _ -> check("daemon", :ok, "not running; a client starts one")
    end
  end

  defp path_check(program, when_missing) do
    case System.find_executable(program) do
      nil -> check("#{program} on PATH", :warn, "not found; #{when_missing}")
      path -> check("#{program} on PATH", :ok, Troupe.Paths.display(path))
    end
  end

  # Every plane the caller knows of, and the one the daemon is linked to, each asked
  # for its discovery document — the request a sign-in starts with.
  defp plane_checks(opts, live?) do
    linked =
      case Troupe.Identity.get() do
        %{plane_url: url} when is_binary(url) and url != "" -> [url]
        _ -> []
      end

    urls =
      opts |> Keyword.get(:planes, []) |> Kernel.++(linked) |> Enum.map(&base/1) |> Enum.uniq()

    case urls do
      [] -> [check("plane", :ok, "none configured")]
      urls -> Enum.map(urls, &plane_check(&1, live?))
    end
  end

  defp plane_check(url, false), do: check("plane #{url}", :ok, "not tried")

  defp plane_check(url, true) do
    case Req.get(url <> "/.well-known/troupe", receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        check("plane #{url}", :ok, "answers" <> plane_name(body))

      {:ok, %Req.Response{status: status}} ->
        check("plane #{url}", :fail, "answered #{status} to /.well-known/troupe; check the URL")

      {:error, %{reason: reason}} ->
        check("plane #{url}", :fail, "not answering: #{inspect(reason)}")

      {:error, reason} ->
        check("plane #{url}", :fail, "not answering: #{inspect(reason)}")
    end
  end

  defp plane_name(body) do
    case get_in(body, ["plane", "name"]) || body["name"] do
      name when is_binary(name) and name != "" -> " (#{name})"
      _ -> ""
    end
  end

  defp base(url), do: url |> String.trim() |> String.trim_trailing("/")

  # -- words ----------------------------------------------------------------------

  defp provider_name(config) do
    case Config.split_model(config, Config.resolve_model(config, :default)) do
      {nil, _bare} ->
        to_string(config.provider)

      {_provider, _bare} ->
        config |> Config.resolve_model(:default) |> String.split("/", parts: 2) |> hd()
    end
  end

  defp key_words(config) do
    target = Config.target(config, nil)

    cond do
      is_binary(target.api_key) and target.api_key != "" -> "key #{Config.mask(target.api_key)}"
      target.provider == "fake" -> "no key needed"
      var = Config.vendor_key_var(target.provider, target.base_url) -> "key from #{var}"
      true -> "no key needed at #{target.base_url}"
    end
  end

  defp next_step("troupe"), do: "run `troupe config`"

  defp next_step(_command),
    do: "write a provider into #{Troupe.Paths.display(Config.user_path())}"

  defp check(name, state, detail), do: %{name: name, state: state, detail: detail}
end
