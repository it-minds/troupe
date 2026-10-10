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
    * `model default`, `model cheap`, `model expensive` — each model the config names,
      among what its provider listed: one it does not serve fails, naming the ones
      nearest it that it does (Decision 778). No line when the provider listed nothing.
    * `identify` — what a session's model calls say about Troupe to the default model's
      provider, header by header as they go out, or `off` (Decision 787): the terminal
      UI's through `troupe`, the desktop app's through the daemon.
    * `key storage` — where the key is kept: the user's `config.yaml`, there being no
      keychain in this build.
    * `reaper` — the helper every command runs under starts (`reaper --version`). One
      that will not start fails: a session still answers, and runs no `shell`, no `git`
      and no MCP server (Decision 733). A build without one warns.
    * `daemon` — whether one is answering, and where; not running is not a failure,
      since a client starts one.
    * `troupe-daemon on PATH`, `troupe on PATH` — a warning when missing, with what
      that means.
    * `plane <url>` — for every plane the caller names, and the one the daemon is
      linked to: its discovery document answers.

  Both programs print the same lines; the differences are which command a line names
  as the next step, `troupe config` through `troupe` and the file through the daemon, and
  which client the `identify` line names.

  `bench/1` is what `troupe doctor --bench` adds after them (Decision 821): the offline
  bench's scenarios, run in this program against a scripted model, a line each and one
  for the whole. `json/2` is any of it as one object.
  """

  alias Troupe.{Config, Executable, Reaper}
  alias Troupe.LLM.{Catalog, Identify}
  alias Troupe.LLM.Catalog.Store
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

    [config_check(resolved), provider_check(resolved, command)] ++
      key_checks(resolved, live?) ++
      [
        identify_check(resolved, client(command)),
        storage_check(),
        reaper_check(workspace),
        daemon_check(),
        path_check(
          "troupe-daemon",
          "a client starts the daemon from the PATH; troupe embeds one"
        ),
        path_check(
          "troupe",
          "the terminal client; the desktop app and troupe-daemon work without it"
        )
      ] ++ plane_checks(opts, live?)
  end

  @doc """
  One line per check, as both programs print them. A name longer than its column (a
  plane's URL) still has a space after it.
  """
  @spec format([check()]) :: String.t()
  def format(checks) do
    Enum.map_join(checks, "", fn check ->
      String.pad_trailing(label(check.state), 6) <>
        String.pad_trailing(check.name, 21) <> " " <> check.detail <> "\n"
    end)
  end

  @doc "1 when any check failed, else 0."
  @spec exit_status([check()]) :: 0 | 1
  def exit_status(checks), do: if(Enum.any?(checks, &(&1.state == :fail)), do: 1, else: 0)

  @doc """
  The lines as one JSON object: `passed`, and `checks`, each a `name`, a `state` (`ok`,
  `warn`, `fail`) and its `detail`. With the bench's part (`bench/1`), `bench` too.
  """
  @spec json([check()], map() | nil) :: String.t()
  def json(checks, bench \\ nil) do
    report = %{
      "passed" => exit_status(checks) == 0,
      "checks" =>
        Enum.map(checks, fn check ->
          %{
            "name" => check.name,
            "state" => Atom.to_string(check.state),
            "detail" => check.detail
          }
        end)
    }

    report = if bench, do: Map.put(report, "bench", bench), else: report
    Jason.encode!(report, pretty: true) <> "\n"
  end

  @doc """
  The offline bench as lines (Decision 821): `troupe bench`'s scenarios (`Troupe.Bench.run/1`),
  a turn of tool calls, a cut tool output, a compaction, a cancel and a replay, each run
  in this program, in directories of its own that are removed afterwards, against the
  scripted model, so it needs no provider, key or network. A scenario's line is `ok` when
  it passed, as `troupe bench` judges it, and `fail` naming what did not hold; the last
  line, `bench`, says how many passed and in how long.

  Answers the lines and the bench's part of `json/2`: `passed`, `seconds`, `scenarios`
  and `failed`, each thing that failed as `scenario/measure`. Options are
  `Troupe.Bench.run/1`'s (`:budgets`, `:only`).
  """
  @spec bench(keyword()) :: {[check()], map()}
  def bench(opts \\ []) do
    {micros, report} = :timer.tc(fn -> Troupe.Bench.run(opts) end)
    bench_lines(report, Float.round(micros / 1_000_000, 1))
  rescue
    # A scenario that fails is in the report; this is the bench not starting at all, its
    # directories not made, say.
    error ->
      {[check("bench", :fail, "did not run: #{Exception.message(error)}")],
       %{"passed" => false, "seconds" => nil, "scenarios" => 0, "failed" => ["bench"]}}
  end

  defp label(:ok), do: "ok"
  defp label(:warn), do: "warn"
  defp label(:fail), do: "FAIL"

  # -- the bench --------------------------------------------------------------------

  defp bench_lines(report, seconds) do
    scenarios = Enum.map(report["scenarios"], &{&1, bench_failures(&1)})
    failed = for {scenario, [_ | _]} <- scenarios, do: scenario["name"]
    lines = Enum.map(scenarios, &scenario_check/1)

    whole =
      case failed do
        [] ->
          check(
            "bench",
            :ok,
            "#{length(scenarios)} of #{length(scenarios)} passed in #{seconds} s, offline: " <>
              "a scripted model in this program's harness, no provider, key or network"
          )

        _ ->
          check(
            "bench",
            :fail,
            "#{length(failed)} of #{length(scenarios)} failed in #{seconds} s: #{Enum.join(failed, ", ")}"
          )
      end

    {lines ++ [whole],
     %{
       "passed" => failed == [],
       "seconds" => seconds,
       "scenarios" => length(scenarios),
       "failed" => for({_scenario, failures} <- scenarios, {id, _words} <- failures, do: id)
     }}
  end

  defp scenario_check({scenario, []}),
    do: check("bench #{scenario["name"]}", :ok, scenario["title"])

  defp scenario_check({scenario, failures}) do
    words = Enum.map_join(failures, "; ", &elem(&1, 1))
    check("bench #{scenario["name"]}", :fail, "#{scenario["title"]}; failed: #{words}")
  end

  # What did not hold in a scenario of the bench's report, each `{scenario/measure, words}`:
  # why it did not run, a measure past its budget, a check, the outcome.
  defp bench_failures(%{"name" => name} = scenario) do
    error = if why = scenario["error"], do: [{name, "did not run: #{why}"}], else: []

    metrics =
      for %{"passed" => false} = metric <- scenario["metrics"],
          do: {"#{name}/#{metric["name"]}", metric_failure(metric)}

    checks =
      for %{"passed" => false} = check <- scenario["checks"],
          do: {"#{name}/#{check["name"]}", "#{check["label"]}: no"}

    outcome =
      case scenario["outcome"] do
        %{"passed" => false, "what" => what} -> [{"#{name}/outcome", "#{what}: no"}]
        _held_or_none -> []
      end

    error ++ metrics ++ checks ++ outcome
  end

  defp metric_failure(%{"value" => nil} = metric),
    do: "#{metric["name"]} has a budget of #{metric["budget"]} and is not measured"

  defp metric_failure(%{"unit" => unit} = metric) when unit in [nil, "share"],
    do: "#{metric["label"]} #{metric["value"]}, over its budget of #{metric["budget"]}"

  defp metric_failure(metric),
    do:
      "#{metric["label"]} #{metric["value"]} #{metric["unit"]}, over its budget of #{metric["budget"]}"

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

  defp key_checks({:error, _error}, _live?),
    do: [check("key", :fail, "not checked: the config files do not load")]

  defp key_checks({:ok, config, _layers}, live?) do
    target = Config.target(config, nil)

    cond do
      Config.key_problem(config) != nil ->
        [check("key", :fail, "not checked: no key")]

      target.provider == "fake" ->
        [check("key", :ok, "the fake provider asks nobody")]

      not live? ->
        [check("key", :ok, "not tried")]

      true ->
        listed = target |> key_params() |> Troupe.Setup.check_key()
        [key_result(listed, target) | model_checks(config, target, listed)]
    end
  end

  # Each model the config names for a role, against what its provider lists (#410): the
  # key line's list for the default model's provider, and one more request for any other
  # provider a role names. A provider that lists nothing or does not answer adds no line;
  # for the default's, the key line has said so.
  defp model_checks(config, default_target, default_listed) do
    lists = %{listing(default_target) => default_listed}

    {checks, _lists} =
      Enum.flat_map_reduce(Store.roles(config), lists, fn {role, model}, lists ->
        target = Config.target(config, model)
        lists = Map.put_new_lazy(lists, listing(target), fn -> listed(target) end)
        {model_check(config, role, model, target, lists[listing(target)]), lists}
      end)

    checks
  end

  defp listing(target), do: Map.take(target, [:provider, :base_url, :api_key, :auth])

  # The fake provider and a refused one are asked nothing.
  defp listed(%{provider: "fake"}), do: {:unknown, "not asked"}
  defp listed(%{api_key: {:refused, _why}}), do: {:unknown, "not asked"}
  defp listed(target), do: target |> key_params() |> Troupe.Setup.check_key()

  defp model_check(config, role, model, target, {:ok, [_ | _] = listed}) do
    ids = Enum.map(listed, & &1.id)
    name = provider_name(config, model)

    if Catalog.serves?(ids, target.model) do
      [check("model #{role}", :ok, "#{model}, served by #{name}")]
    else
      [
        check(
          "model #{role}",
          :fail,
          "#{model} is not served by #{name}; it serves #{alternatives(config, model, target, ids)}; " <>
            "set models.#{role} to one"
        )
      ]
    end
  end

  defp model_check(_config, _role, _model, _target, _not_listed), do: []

  # The served ids nearest the name first, five of them, each as the role would name it.
  defp alternatives(config, model, target, ids) do
    prefix = if name = named(config, model), do: name <> "/", else: ""
    shown = target.model |> Catalog.nearest(ids, 5) |> Enum.map_join(", ", &(prefix <> &1))

    case length(ids) - 5 do
      more when more > 0 -> "#{shown} and #{more} more"
      _all -> shown
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

  # Built by the function the adapters build their headers with, so the two cannot differ.
  defp identify_check({:error, _error}, _client),
    do: check("identify", :fail, "not checked: the config files do not load")

  defp identify_check({:ok, config, _layers}, client) do
    target = Config.target(config, nil)

    case target.provider do
      "fake" ->
        check("identify", :ok, "nothing goes out: the fake provider asks nobody")

      type ->
        check(
          "identify",
          :ok,
          Identify.describe(config.identify != false, client, type, target.base_url)
        )
    end
  end

  # The client a session started through this program is: `troupe` is the terminal UI,
  # and `troupe-daemon` the desktop app's daemon.
  defp client("troupe"), do: "tui"
  defp client(_command), do: "desktop"

  defp storage_check do
    check(
      "key storage",
      :ok,
      "#{Troupe.Paths.display(Config.user_path())}; there is no OS keychain in this build"
    )
  end

  # Started as a session would start it, in the workspace: what it prints for `--version`
  # is proof it ran.
  defp reaper_check(workspace) do
    case Reaper.run(workspace, ["--version"], timeout_ms: 10_000) do
      {:ok, out, 0} ->
        {:ok, path} = Reaper.path()
        check("reaper", :ok, "#{String.trim(out)}, #{Troupe.Paths.display(path)}")

      {:ok, _out, :timeout} ->
        check("reaper", :fail, "the reaper helper did not answer `--version` in 10 s; reinstall")

      {:ok, out, status} ->
        check(
          "reaper",
          :fail,
          "the reaper helper exited #{status}: #{String.trim(out)}; reinstall"
        )

      {:error, :reaper_missing} ->
        check(
          "reaper",
          :warn,
          "#{Reaper.explain(:reaper_missing)}; no shell or git: `mix compile.reaper` builds it"
        )

      {:error, reason} ->
        check(
          "reaper",
          :fail,
          "#{Reaper.explain(reason)}, so a session runs no shell, git or MCP server; " <>
            "let it run (an antivirus, a noexec mount) or reinstall"
        )
    end
  end

  defp daemon_check do
    with {:ok, endpoint} <- Endpoint.discover(),
         true <- Daemon.running?(endpoint: endpoint) do
      check("daemon", :ok, "running at #{Endpoint.describe(endpoint)}")
    else
      _ -> check("daemon", :ok, "not running; a client starts one")
    end
  end

  # As a session looks for it: on the PATH alone (Decision 846).
  defp path_check(program, when_missing) do
    case Executable.find(program) do
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

  defp provider_name(config, model \\ :default),
    do: named(config, model) || to_string(config.provider)

  # The named provider a model goes to, or `nil` for the session-wide one.
  defp named(config, model) do
    model = Config.resolve_model(config, model)

    case Config.split_model(config, model) do
      {nil, _bare} -> nil
      {_provider, _bare} -> model |> String.split("/", parts: 2) |> hd()
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
