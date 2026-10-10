defmodule Troupe.CLI.ConfigSetup do
  @moduledoc """
  `troupe config`: the resolved settings, or a first run when there are none.

  A machine with a `config.yaml`, or with its provider in `TROUPE_*` variables, or with a
  vendor's key in the environment (`ANTHROPIC_API_KEY`), gets the report `troupe config`
  has always printed. A machine with none of those has nothing to report, and on a
  terminal this asks how it should reach a model instead:

    * opencode is set up here: Troupe reads none of opencode's settings (root Decision
      828), so this offers to copy its providers into `config.yaml` (`config.import`),
      keys as opencode has them written; a no goes on to the ways below.
    * otherwise, three ways on: set a provider up here (Anthropic first, then OpenAI or a
      gateway: provider, URL and key, then a model from what the provider lists, through
      `config.models` and `config.set`); take an organisation's settings from a Troupe
      plane (`troupe login`, then `troupe config pull`); or not now, which says where
      each of those lives.

  Settings saved here end with the question the desktop app's first run asks last, where
  `troupe-daemon` is installed: whether it starts at login (`troupe daemon login on`).

  A `config.yaml` through which no model can be asked (`Troupe.Config.key_problem/1`)
  gets the report, whose last line names `troupe config` as the next step, and then the
  same three ways on. Without a terminal it asks nothing and prints the ways on. Every
  read and write goes through the daemon, as `troupe config pull` does: the daemon is the
  process whose environment decides which `config.yaml` a session reads.

  `troupe setup` asks the daemon's own first-run questions (`setup.get`, `setup.answer`;
  root Decision 705) as one full screen, `Troupe.UI.Setup`, at any time, and ends in the
  first session it started (`setup/2`; TUI Decision 153). Plain `troupe` opens that screen
  before it opens a session on a machine with no settings and no key (`before_session/2`),
  so a first run meets the setup rather than a model error — unless the daemon says the
  first run was done already, in the desktop app or by hand, in which case nothing is
  asked. A daemon from before `setup.get`, and a terminal the screen cannot be drawn on,
  get the questions here, line by line, as `troupe config` asks them.
  """

  alias Troupe.CLI.{ModelConfig, Prompt, Terminal}
  alias Troupe.CLI.Remote, as: RemoteCLI
  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol

  @typedoc """
  Everything this touches outside itself, so a test can play a person and a daemon:
  `say` prints a line, `ask` reads one (`nil` at end of input), `secret` reads one
  without echo, `call` is a daemon request, `login` and `pull` are the commands of the
  same names, `describe` is the full report, `opencode` the providers opencode's settings
  declare, as the daemon finds them to offer the copy (`setup.get`'s `detected`),
  `usable?` whether the settings in force can ask a model, and
  `troupe_daemon?` and `troupe_daemon` whether there is a standalone daemon binary and
  `troupe daemon ARGS` run through it. `not_terminal` names standard input or output when
  either is not a terminal, `screen` runs the full-screen setup on the flow `setup.get`
  answered and says how it ended (`Troupe.UI.Setup`), and `open` attaches to a session.
  """
  @type io :: %{
          interactive?: boolean(),
          not_terminal: [String.t()],
          say: (String.t() -> any()),
          ask: (String.t() -> String.t() | nil),
          secret: (String.t() -> String.t() | nil),
          call: (String.t(), map() -> {:ok, map()} | {:error, term()}),
          login: (String.t() -> non_neg_integer()),
          pull: (String.t() -> non_neg_integer()),
          describe: (-> String.t()),
          opencode: (-> %{names: [String.t()], default: String.t() | nil}),
          local_file?: (-> boolean()),
          usable?: (-> boolean()),
          troupe_daemon?: (-> boolean()),
          troupe_daemon: ([String.t()] -> non_neg_integer()),
          screen: (map() -> Troupe.UI.Setup.outcome() | {:cannot_draw, String.t()}),
          open: (Path.t(), String.t() -> {:ok, String.t()} | {:error, term()})
        }

  @doc "Run `troupe config` for a workspace; returns the exit status."
  @spec run(Path.t(), io() | nil) :: non_neg_integer()
  def run(workspace, io \\ nil) do
    io = io || io(workspace)

    # The common case, a machine that is set up, needs no daemon to say so.
    if io.local_file?.() and io.usable?.() do
      report(io)
    else
      case io.call.("config.get", %{}) do
        {:ok, %{"exists" => true} = settings} ->
          if io.usable?.(), do: report(io), else: no_key(settings, io)

        {:ok, %{"api_key_source" => "env"}} ->
          report(io)

        {:ok, settings} ->
          if io.usable?.(), do: report(io), else: first_run(settings, io)

        {:error, reason} ->
          daemon_down(reason, io)
      end
    end
  end

  @doc """
  What plain `troupe` does before it opens a session: on a machine with no `config.yaml`
  and no key in force, the full-screen setup (TUI Decision 153), whose first session is
  the one to open (`{:open, session_id}`); or one line saying to run `troupe config`
  where there is no terminal to ask on. Anything else goes on to a session at once.
  """
  @spec before_session(Path.t(), io() | nil) :: :ok | {:open, String.t()}
  def before_session(workspace, io \\ nil) do
    io = io || io(workspace)

    cond do
      io.local_file?.() or io.usable?.() ->
        :ok

      not io.interactive? ->
        io.say.("No provider is set up yet: run `troupe config` to set one up.")
        :ok

      true ->
        case io.call.("setup.get", %{}) do
          # A first run done in the desktop app is recorded once, for both clients; the
          # daemon says so, and this asks nothing (TUI Decision 123).
          {:ok, %{"needed" => false}} ->
            :ok

          {:ok, flow} ->
            case flow |> io.screen.() |> ended(io) do
              {:open, sid} -> {:open, sid}
              _status -> :ok
            end

          # A daemon from before the first run's questions answers `method_not_found`:
          # then nothing says it was done, and `troupe config`'s questions are asked.
          {:error, _reason} ->
            old_questions(io)
        end
    end
  end

  # The daemon may know better than this process: a file, or a key in its environment.
  defp old_questions(io) do
    case io.call.("config.get", %{}) do
      {:ok, %{"exists" => true}} ->
        :ok

      {:ok, %{"api_key_source" => "env"}} ->
        :ok

      {:ok, settings} ->
        _ = first_run(settings, io)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  `troupe setup`: the daemon's first-run questions as one screen, at any time, whatever is
  set up already (TUI Decision 153). It ends in the first session, `{:open, session_id}`,
  which the caller opens; or in an exit status, after saying how it ended. Where it cannot
  be drawn it says why and asks `troupe config`'s questions line by line, which without a
  terminal to ask on are the ways on.
  """
  @spec setup(Path.t(), io() | nil) :: {:open, String.t()} | non_neg_integer()
  def setup(workspace, io \\ nil) do
    io = io || io(workspace)

    if io.interactive? do
      case io.call.("setup.get", %{}) do
        {:ok, flow} ->
          flow |> io.screen.() |> ended(io)

        {:error, reason} ->
          io.say.(
            "troupe setup: the daemon does not ask the first run's questions " <>
              "(#{describe_error(reason)}); they are asked here, line by line."
          )

          line_by_line(io)
      end
    else
      which =
        case io.not_terminal do
          [one] -> "#{one} is not a terminal"
          both -> "#{Enum.join(both, " and ")} are not terminals"
        end

      io.say.("troupe setup: #{which}, so there is no screen to draw and nobody to ask.")

      _ = line_by_line(io)
      1
    end
  end

  # `troupe config`'s questions, from the top, whatever is set up: what `troupe setup`
  # falls back to.
  defp line_by_line(io) do
    path =
      case io.call.("config.get", %{}) do
        {:ok, %{"path" => path}} -> path
        _ -> Troupe.Config.user_path()
      end

    path = Troupe.Paths.display(path)

    if io.interactive? do
      choose(path, io)
    else
      ways_on(path, io)
      0
    end
  end

  # How the screen ended, said, and the session it started to open.
  defp ended({:session, sid, workspace}, io) do
    case io.open.(workspace, sid) do
      {:ok, sid} ->
        {:open, sid}

      {:error, reason} ->
        io.say.(
          "Set up. The first session started but could not be opened here " <>
            "(#{describe_error(reason)}): troupe resume #{sid} opens it."
        )

        1
    end
  end

  defp ended({:no_session, reason}, io) do
    io.say.("Set up. The first session did not start: #{reason}")
    1
  end

  # Signing in is the client's (root Decision 705): as `troupe config`'s plane choice does.
  defp ended({:plane, url}, io) when url in [nil, ""] do
    io.say.("Recorded. Sign in with troupe login <plane-url>, then troupe config pull.")
    0
  end

  defp ended({:plane, url}, io), do: if(io.login.(url) == 0, do: io.pull.(url), else: 1)

  defp ended({:left, false}, io) do
    io.say.("Left the setup with nothing written; troupe setup asks again.")
    0
  end

  defp ended({:left, true}, io) do
    io.say.("Left the setup; what it saved before that stays. troupe setup asks again.")
    0
  end

  defp ended({:cannot_draw, reason}, io) do
    io.say.("troupe setup: the screen could not be drawn (#{reason}); the questions, line by line:")
    line_by_line(io)
  end

  defp report(io) do
    io.say.(io.describe.())
    0
  end

  # A file through which no model can be asked: the report says why and names this
  # command as the next step, so in a terminal the next step is here.
  defp no_key(%{"path" => path}, io) do
    io.say.(io.describe.())
    if io.interactive?, do: choose(Troupe.Paths.display(path), io), else: 0
  end

  defp daemon_down(reason, io) do
    io.say.(io.describe.())
    io.say.("could not ask the daemon about the model settings: #{inspect(reason)}")
    1
  end

  defp first_run(%{"path" => path}, io) do
    path = Troupe.Paths.display(path)
    opencode = io.opencode.()

    io.say.("No model settings yet: #{path} does not exist.")

    cond do
      opencode.names != [] ->
        offer_opencode(path, opencode, io)

      io.interactive? ->
        choose(path, io)

      true ->
        ways_on(path, io)
        0
    end
  end

  # -- opencode -----------------------------------------------------------------

  defp offer_opencode(path, opencode, io) do
    io.say.("")

    io.say.(
      "opencode is set up here, with #{Enum.join(opencode.names, ", ")}" <>
        if(opencode.default, do: " (default model #{opencode.default}).", else: ".")
    )

    io.say.("Troupe doesn't read opencode's settings; a copy makes them Troupe's own.")

    cond do
      not io.interactive? ->
        io.say.("`troupe config` in a terminal can copy them into #{path}.")
        0

      yes?(io, "Copy them into #{path}, keys as opencode has them written?", true) ->
        io |> import_opencode() |> at_login(io)

      true ->
        io.say.("Not copied.")
        choose(path, io)
    end
  end

  defp import_opencode(io) do
    case io.call.("config.import", %{"command_id" => Protocol.command_id(), "from" => "opencode"}) do
      {:ok, %{"imported" => imported} = saved} ->
        io.say.("copied into #{saved["path"]}: #{Enum.join(imported["providers"], ", ")}")

        if imported["kept"] != [],
          do: io.say.("  kept #{Enum.join(imported["kept"], ", ")}, already there")

        if imported["default"], do: io.say.("  default model #{imported["default"]}")
        0

      {:error, reason} ->
        io.say.("could not copy opencode's config: #{describe_error(reason)}")
        1
    end
  end

  # -- the three ways on ----------------------------------------------------------

  # The simplest first: a key of one's own, which is what a fresh machine has. Enter
  # takes it.
  defp choose(path, io) do
    io.say.("")
    io.say.("How should this machine reach a model?")
    io.say.("  1  set up a provider here: an Anthropic or OpenAI key, or a gateway such as LiteLLM")
    io.say.("  2  take your organisation's settings from its Troupe plane")
    io.say.("  3  not now")

    case io.ask.("choice [1]: ") do
      answer when answer in ["", "1"] ->
        path |> set_up_here(io) |> at_login(io)

      "2" ->
        from_plane(io)

      _other ->
        ways_on(path, io)
        0
    end
  end

  defp ways_on(path, io) do
    io.say.("")
    io.say.("When you are ready, either:")
    io.say.("  * write #{path} with a provider; the simplest is a key in the environment:")
    io.say.("      provider: anthropic")
    io.say.("      api_key: \"{env:ANTHROPIC_API_KEY}\"")
    io.say.("    or a gateway such as LiteLLM, anything speaking Chat Completions:")
    io.say.("      provider: openai")
    io.say.("      base_url: https://llm-gw.example/v1")
    io.say.("      api_key: \"{env:MY_GATEWAY_KEY}\"")
    io.say.("      models: {default: some-model, cheap: a-smaller-model}")

    io.say.(
      "  * take your organisation's settings: troupe login <plane-url>, then troupe config pull"
    )

    io.say.("  * or set it up in the desktop app (This computer > Models)")
    io.say.("Then troupe config shows what Troupe will use.")
  end

  defp from_plane(io) do
    case io.ask.("plane URL: ") do
      url when url in [nil, ""] ->
        io.say.("no plane given; nothing changed")
        1

      url ->
        if io.login.(url) == 0, do: io.pull.(url), else: 1
    end
  end

  defp set_up_here(path, io) do
    provider =
      case io.ask.(
             "provider: 1 Anthropic, 2 OpenAI or an OpenAI-compatible gateway (LiteLLM, vLLM, OpenRouter) [1]: "
           ) do
        "2" -> "openai"
        _ -> "anthropic"
      end

    base_url = io.ask.(base_url_prompt(provider)) |> blank_to_nil()
    fallback = vendor_key(provider, base_url)
    key = blank_to_nil(io.secret.(key_prompt(fallback))) || fallback
    params = %{"provider" => provider, "base_url" => base_url, "api_key" => key}

    with {:ok, default, cheap} <- pick_models(params, io),
         true <-
           yes?(io, "Save #{provider}#{at(base_url)}, default model #{default}, to #{path}?", true) do
      save(params, %{"default" => default, "cheap" => cheap}, io)
    else
      false ->
        io.say.("nothing saved")
        1

      {:error, message} ->
        io.say.(message)
        1
    end
  end

  defp base_url_prompt("openai"),
    do: "base URL (a gateway's, ending in /v1; Enter for api.openai.com): "

  defp base_url_prompt(_), do: "base URL (Enter for the provider's own): "

  # The vendor's own variable, at the vendor's own endpoint: what Enter at the key prompt
  # saves, so the simplest setup is a key in the environment and a reference to it in the
  # file. A gateway has a key of its own, or needs none.
  defp vendor_key(provider, base_url) do
    case Troupe.Config.vendor_key_var(provider, base_url) do
      nil -> nil
      var -> "{env:#{var}}"
    end
  end

  defp key_prompt(nil), do: "API key, or {env:VAR} to read it from the environment: "

  defp key_prompt(reference),
    do: "API key, or {env:VAR} to read it from the environment [#{reference}]: "

  # The provider says what it serves; a key given as `{env:VAR}` is looked up for the
  # asking, and saved as the reference.
  defp pick_models(params, io) do
    ask_params =
      params
      |> Map.update!("api_key", &(&1 && blank_to_nil(Troupe.Config.interpolate(&1))))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    listed =
      case io.call.("config.models", ask_params) do
        {:ok, %{"models" => models} = found} ->
          Enum.each(found["failures"] || [], &io.say.("  #{&1["provider"]}: #{&1["reason"]}"))
          Enum.map(models, & &1["id"])

        {:error, reason} ->
          io.say.("could not list the provider's models: #{describe_error(reason)}")
          []
      end

    choose_models(listed, params["provider"], io)
  end

  # Nothing listed, usually for want of a key yet. Anthropic's default is worth offering,
  # the model Troupe uses when nothing names one; anything else is typed out.
  defp choose_models([], provider, io) do
    fallback = if provider == "anthropic", do: %Troupe.Config{}.model
    prompt = if fallback, do: "default model id [#{fallback}]: ", else: "default model id: "

    case blank_to_nil(io.ask.(prompt)) || fallback do
      nil -> {:error, "no model given; nothing saved"}
      default -> {:ok, default, io.ask.("cheap model id (Enter: the same): ") |> blank_to_nil()}
    end
  end

  defp choose_models(ids, _provider, io) do
    io.say.("The provider serves:")

    ids
    |> Enum.with_index(1)
    |> Enum.each(fn {id, n} -> io.say.("  #{String.pad_leading(to_string(n), 3)}  #{id}") end)

    default = pick(ids, io.ask.("default model [1]: "), hd(ids))
    cheap = pick(ids, io.ask.("cheap model (Enter: the same): "), nil)
    {:ok, default, cheap}
  end

  # A number from the list, an id typed out, or the fallback for nothing at all.
  defp pick(ids, answer, fallback) do
    case blank_to_nil(answer) do
      nil ->
        fallback

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 1 and n <= length(ids) -> Enum.at(ids, n - 1)
          _ -> text
        end
    end
  end

  defp save(params, models, io) do
    params =
      params
      |> Map.put("command_id", Protocol.command_id())
      |> Map.put("models", models |> Enum.reject(fn {_role, id} -> is_nil(id) end) |> Map.new())
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case io.call.("config.set", params) do
      {:ok, saved} ->
        io.say.("saved to #{Troupe.Paths.display(saved["path"])}")

        cond do
          # Saved as it is, and refused until the variable is set: better said now than
          # on the first turn.
          var = unset_variable(params["api_key"]) ->
            io.say.("note: #{var} is not set in this shell; set it before you start troupe")

          not saved["api_key_set"] ->
            io.say.("note: no key is in force yet; set the variable it names")

          true ->
            :ok
        end

        0

      {:error, reason} ->
        io.say.("could not save: #{describe_error(reason)}")
        1
    end
  end

  # -- at login -----------------------------------------------------------------

  # The question the desktop app's first run asks last (root Decision 762): whether the
  # daemon starts when this person logs in. Asked once the settings are saved, only
  # where there is a `troupe-daemon` to start, and Enter is no; yes is `troupe daemon
  # login on`, which says what it wrote.
  defp at_login(0, io) do
    if io.troupe_daemon?.() and
         yes?(
           io,
           "Start troupe-daemon when you log in, so it is running before any window is?",
           false
         ),
       do: io.troupe_daemon.(["login", "on"]),
       else: 0
  end

  defp at_login(status, _io), do: status

  # -- helpers ------------------------------------------------------------------

  defp yes?(io, question, default) do
    hint = if default, do: "[Y/n]", else: "[y/N]"

    case io.ask.("#{question} #{hint} ") |> blank_to_nil() do
      nil -> default
      answer -> String.downcase(answer) in ["y", "yes"]
    end
  end

  defp at(nil), do: ""
  defp at(url), do: " at #{url}"

  defp unset_variable(key) when is_binary(key) do
    case Regex.run(~r/^\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/, key) do
      [_, var] -> if System.get_env(var) in [nil, ""], do: var
      nil -> nil
    end
  end

  defp unset_variable(_key), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp describe_error(%{message: message}) when is_binary(message), do: message
  defp describe_error(%{"message" => message}) when is_binary(message), do: message
  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  # -- the real world -------------------------------------------------------------

  @doc false
  @spec io(Path.t()) :: io()
  def io(workspace) do
    %{
      interactive?: terminal?(),
      not_terminal:
        for(
          {name, terminal?} <- [
            {"standard input", Terminal.stdin?()},
            {"standard output", Terminal.stdout?()}
          ],
          not terminal?,
          do: name
        ),
      say: &IO.puts/1,
      ask: &ask/1,
      secret: &secret/1,
      call: &Link.call/2,
      login: &RemoteCLI.login/1,
      pull: &ModelConfig.pull/1,
      describe: fn -> describe(workspace) end,
      opencode: &opencode/0,
      local_file?: fn -> File.regular?(Troupe.Config.user_path()) end,
      usable?: fn -> usable?(workspace) end,
      troupe_daemon?: fn -> match?({:ok, _path}, Troupe.CLI.Daemon.command()) end,
      troupe_daemon: &Troupe.CLI.Daemon.run/1,
      screen: &screen(workspace, &1),
      open: &Troupe.Client.open_session({:local, &1}, &2)
    }
  end

  # The screen runs as the terminal UI does, under `Troupe.UI.Windows`, and this waits for
  # how it ended and for it to give the terminal back, before a session's window takes it.
  # The fake provider is offered only where a script for it is set up (TUI Decision 153).
  defp screen(workspace, flow) do
    me = self()
    ref = make_ref()

    opts = [
      call: &Link.call/2,
      flow: flow,
      workspace: workspace,
      offer_fake: System.get_env("TROUPE_FAKE_SCRIPT") not in [nil, ""],
      on_done: fn outcome -> send(me, {ref, outcome}) end,
      name: nil
    ]

    spec = %{
      id: Troupe.UI.Setup,
      start: {Troupe.UI.Setup, :start_link, [opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Troupe.UI.Windows, spec) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        receive do
          {^ref, outcome} ->
            receive do
              {:DOWN, ^monitor, _, _, _} -> :ok
            after
              5_000 -> DynamicSupervisor.terminate_child(Troupe.UI.Windows, pid)
            end

            outcome

          {:DOWN, ^monitor, _, _, reason} ->
            {:cannot_draw, Exception.format_exit(reason)}
        end

      {:error, reason} ->
        {:cannot_draw, describe_error(reason)}
    end
  end

  # Standard output as the person sees it, which in the binary on Linux and macOS is the
  # launcher's, not the VM's (`Troupe.CLI.Terminal`).
  defp terminal?, do: Terminal.stdin?() and Terminal.stdout?()

  # On Windows the binary's VM reads no line the way the console edits one, so a question
  # there reads it key by key (`Troupe.CLI.Prompt` says why).
  defp ask(prompt) do
    line = if windows?(), do: Prompt.read(prompt), else: IO.gets(prompt)

    case line do
      line when is_binary(line) -> String.trim(line)
      _eof -> nil
    end
  end

  # Unechoed where the terminal allows it: `-noshell` reads lines cooked, and only raw
  # mode lets `get_password` turn the echo off. Where it will not, the prompt says so.
  defp secret(prompt) do
    if windows?(), do: prompt |> Prompt.read(echo: false) |> trim(), else: echo_off(prompt)
  end

  defp trim(line) when is_binary(line), do: String.trim(line)
  defp trim(nil), do: nil

  defp windows?, do: match?({:win32, _}, :os.type())

  defp echo_off(prompt) do
    IO.write(prompt)

    password =
      case :shell.start_interactive({:noshell, :raw}) do
        :ok ->
          read = :io.get_password()
          :shell.start_interactive({:noshell, :cooked})
          read

        other ->
          other
      end

    IO.puts("")

    if is_list(password) or is_binary(password),
      do: password |> to_string() |> String.trim(),
      else: ask("(this terminal will show it) " <> prompt)
  end

  # A refused file is the report: what is wrong, where, and what to write instead.
  defp describe(workspace) do
    case Troupe.Config.resolve(workspace) do
      {:ok, config, _layers} -> Troupe.Config.describe(config, command: "troupe")
      {:error, error} -> Exception.message(error)
    end
  end

  # Read here, from the files and the environment the daemon this process embeds reads
  # too. A refused file is not a missing key: its report says what is wrong instead.
  defp usable?(workspace) do
    case Troupe.Config.resolve(workspace) do
      {:ok, config, _layers} -> Troupe.Config.key_problem(config) == nil
      {:error, _error} -> true
    end
  end

  # What opencode's settings declare, as the daemon finds them for the first run's offer
  # to copy them; nothing, from a daemon that has no first run to ask.
  defp opencode do
    case Link.call("setup.get", %{}) do
      {:ok, %{"detected" => %{"opencode" => %{"providers" => names} = found}}}
      when is_list(names) ->
        %{names: names, default: found["default"]}

      _other ->
        %{names: [], default: nil}
    end
  end
end
