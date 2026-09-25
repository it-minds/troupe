defmodule Troupe.CLI.ConfigSetup do
  @moduledoc """
  `troupe config`: the resolved settings, or a first run when there are none.

  A machine with a `config.yaml`, or with its provider in `TROUPE_*` variables, gets the
  report `troupe config` has always printed. A machine with neither has nothing to
  report, and on a terminal this asks how it should reach a model instead:

    * opencode is set up here: Troupe already reads opencode's providers while it has
      none of its own, and this offers to copy them into `config.yaml` (`config.import`),
      keys as opencode has them written, so the machine stops depending on opencode.
    * otherwise, three ways on: take an organisation's settings from a Troupe plane
      (`troupe login`, then `troupe config pull`); set a provider up here (provider, URL
      and key, then a model from what the provider lists, through `config.models` and
      `config.set`); or not now, which says where each of those lives.

  Without a terminal it asks nothing and prints the same ways on. Every read and write
  goes through the daemon, as `troupe config pull` does: the daemon is the process whose
  environment decides which `config.yaml` a session reads.
  """

  alias Troupe.CLI.ModelConfig
  alias Troupe.CLI.Remote, as: RemoteCLI
  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol

  @typedoc """
  Everything this touches outside itself, so a test can play a person and a daemon:
  `say` prints a line, `ask` reads one (`nil` at end of input), `secret` reads one
  without echo, `call` is a daemon request, `login` and `pull` are the commands of the
  same names, `describe` is the full report and `opencode` the providers Troupe is
  reading from opencode right now.
  """
  @type io :: %{
          interactive?: boolean(),
          say: (String.t() -> any()),
          ask: (String.t() -> String.t() | nil),
          secret: (String.t() -> String.t() | nil),
          call: (String.t(), map() -> {:ok, map()} | {:error, term()}),
          login: (String.t() -> non_neg_integer()),
          pull: (String.t() -> non_neg_integer()),
          describe: (-> String.t()),
          opencode: (-> %{names: [String.t()], default: String.t() | nil}),
          local_file?: (-> boolean())
        }

  @doc "Run `troupe config` for a workspace; returns the exit status."
  @spec run(Path.t(), io() | nil) :: non_neg_integer()
  def run(workspace, io \\ nil) do
    io = io || io(workspace)

    # The common case, a machine that is set up, needs no daemon to say so.
    if io.local_file?.() do
      io.say.(io.describe.())
      0
    else
      case io.call.("config.get", %{}) do
        {:ok, %{"exists" => true}} -> report(io)
        {:ok, %{"api_key_source" => "env"}} -> report(io)
        {:ok, settings} -> first_run(settings, io)
        {:error, reason} -> daemon_down(reason, io)
      end
    end
  end

  defp report(io) do
    io.say.(io.describe.())
    0
  end

  defp daemon_down(reason, io) do
    io.say.(io.describe.())
    io.say.("could not ask the daemon about the model settings: #{inspect(reason)}")
    1
  end

  defp first_run(%{"path" => path} = settings, io) do
    opencode = io.opencode.()

    io.say.("No model settings yet: #{path} does not exist.")

    cond do
      settings["api_key_source"] == "opencode" and opencode.names != [] ->
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

    io.say.("Troupe uses those as they are while it has no settings of its own.")

    cond do
      not io.interactive? ->
        io.say.("`troupe config` in a terminal can copy them into #{path}.")
        0

      yes?(io, "Copy them into #{path}, keys as opencode has them written?", true) ->
        import_opencode(io)

      true ->
        io.say.("Left as it is: Troupe keeps reading opencode's config.")
        0
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

  defp choose(path, io) do
    io.say.("")
    io.say.("How should this machine reach a model?")
    io.say.("  1  take your organisation's settings from its Troupe plane")
    io.say.("  2  set up a provider here: an API key, or a gateway such as LiteLLM")
    io.say.("  3  not now")

    case io.ask.("choice [1]: ") do
      answer when answer in ["", "1"] ->
        from_plane(io)

      "2" ->
        set_up_here(path, io)

      _other ->
        ways_on(path, io)
        0
    end
  end

  defp ways_on(path, io) do
    io.say.("")
    io.say.("When you are ready, either:")

    io.say.(
      "  * take your organisation's settings: troupe login <plane-url>, then troupe config pull"
    )

    io.say.("  * write #{path} with a provider, for example:")
    io.say.("      provider: openai            # anything speaking Chat Completions; or anthropic")
    io.say.("      base_url: https://llm-gw.example/v1")
    io.say.("      api_key: \"{env:MY_GATEWAY_KEY}\"")
    io.say.("      models: {default: some-model, cheap: a-smaller-model}")
    io.say.("  * or set it in the desktop app's Models settings")
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
             "provider: 1 OpenAI-compatible (OpenAI, LiteLLM, vLLM, OpenRouter), 2 Anthropic [1]: "
           ) do
        "2" -> "anthropic"
        _ -> "openai"
      end

    base_url = io.ask.(base_url_prompt(provider)) |> blank_to_nil()

    key =
      io.secret.("API key, or {env:VAR} to read it from the environment: ")
      |> blank_to_nil()

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

  # The provider says what it serves; a key given as `{env:VAR}` is looked up for the
  # asking, and saved as the reference.
  defp pick_models(params, io) do
    ask_params =
      params
      |> Map.update!("api_key", &(&1 && Troupe.Config.interpolate(&1)))
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

    choose_models(listed, io)
  end

  defp choose_models([], io) do
    case io.ask.("default model id: ") |> blank_to_nil() do
      nil -> {:error, "no model given; nothing saved"}
      default -> {:ok, default, io.ask.("cheap model id (Enter: the same): ") |> blank_to_nil()}
    end
  end

  defp choose_models(ids, io) do
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
        io.say.("saved to #{saved["path"]}")

        unless saved["api_key_set"],
          do: io.say.("note: no key is in force yet; set the variable it names")

        0

      {:error, reason} ->
        io.say.("could not save: #{describe_error(reason)}")
        1
    end
  end

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
      say: &IO.puts/1,
      ask: &ask/1,
      secret: &secret/1,
      call: &Link.call/2,
      login: &RemoteCLI.login/1,
      pull: &ModelConfig.pull/1,
      describe: fn -> describe(workspace) end,
      opencode: fn -> opencode(workspace) end,
      local_file?: fn -> File.regular?(Troupe.Config.user_path()) end
    }
  end

  defp terminal? do
    opts = :io.getopts(:standard_io)
    Keyword.get(opts, :stdin) == true and Keyword.get(opts, :stdout) == true
  end

  defp ask(prompt) do
    case IO.gets(prompt) do
      line when is_binary(line) -> String.trim(line)
      _eof -> nil
    end
  end

  # Unechoed where the terminal allows it: `-noshell` reads lines cooked, and only raw
  # mode lets `get_password` turn the echo off. Where it will not, the prompt says so.
  defp secret(prompt) do
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
      {:ok, config, _layers} -> Troupe.Config.describe(config)
      {:error, error} -> Exception.message(error)
    end
  end

  defp opencode(workspace) do
    config =
      case Troupe.Config.resolve(workspace) do
        {:ok, config, _layers} -> config
        {:error, _error} -> %Troupe.Config{}
      end

    names =
      config.providers
      |> Enum.filter(fn {_name, provider} -> provider.source == :opencode end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    %{
      names: names,
      default: if(names != [] and String.contains?(config.model, "/"), do: config.model)
    }
  end
end
