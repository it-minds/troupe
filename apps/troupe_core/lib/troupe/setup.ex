defmodule Troupe.Setup do
  @moduledoc """
  A first run's questions, in one place (Decision 705): the steps, what each answer
  means, and what each one writes — so the terminal client and the desktop app ask the
  same things in the same order, and a person who answered in one is not asked again in
  the other.

  The flow is a value, `t/0`, that the daemon holds while one is in progress
  (`Troupe.Gateway.Setup`, behind `setup.get` and `setup.answer`), and every move is
  `answer/4`: the name of a step and its answer, checked, and the flow one step on.
  Answering a step already answered goes back to it and forgets what came after, which
  is how a person changes their mind, and how a client re-runs the whole thing.

  The steps, and what each one writes:

    * `where` — this machine and its own keys, or an organisation's plane. A plane is
      the client's to sign in to (`troupe login`, the app's sign-in screen); the flow only
      records the choice and finishes.
    * `provider` — Anthropic, OpenAI, an OpenAI-compatible gateway with a base URL, or a
      LiteLLM proxy; or what is already here: opencode's providers, copied into
      `config.yaml` as `config.import` does, or a `config.yaml` that already works.
    * `key` — pasted, or kept in the environment as `{env:VAR}`. Checked live, with a
      real request to the provider (`check_key/1`): a refused key keeps the step, and a
      provider that will not list its models lets the person go on and type a model id.
      There is no keychain in this build, so the key goes into the user's `config.yaml`,
      readable by the user alone on Unix, and the flow says so (`key_storage/0`).
    * `models` — the main and the small model from what the provider listed, with a
      suggestion that is a safe answer. Writes the provider, the key and the models into
      the user's `config.yaml` through `Troupe.Config.ModelSettings`, never a repository's
      `.troupe/`.
    * `workspace` — the first project directory, and the approval model in two
      sentences: ask first (the default), or every call runs. Writes `auto_approve`.
    * `finish` — records that the first run is done (`<state>/setup.json`), and says
      which session to start, with a suggested prompt; the daemon starts it.

  `needed?/0` is what both clients ask before offering the questions: no record, no
  `config.yaml`, and no model that can be asked. A key never appears in a report: a
  client sees where the key came from, not what it is.
  """

  alias Troupe.Config
  alias Troupe.Config.{ModelSettings, OpenCode}
  alias Troupe.LLM.Catalog
  alias Troupe.LLM.Catalog.Store
  alias Troupe.LLM.Endpoint

  @steps ~w(where provider key models workspace finish)
  @providers ~w(anthropic openai fake)
  @kinds ~w(anthropic openai gateway litellm)
  @vendor_vars ~w(ANTHROPIC_API_KEY OPENAI_API_KEY)
  @approvals ~w(ask auto)
  @env_reference ~r/^\{env:([A-Za-z_][A-Za-z0-9_]*)\}$/

  defstruct step: "where",
            # Each answered step, as it was accepted; the key is never in here.
            answers: %{},
            # The key, held for the flow and sent to the provider it was typed for. Written
            # as typed, or as the `{env:VAR}` reference when it came from the environment.
            key: nil,
            # What the provider listed when the key was checked, and the safe answer.
            offered: [],
            suggested: %{"default" => nil, "cheap" => nil},
            # The last key check: `%{"state" => "ok" | "refused" | "unknown", "reason"}`.
            check: nil,
            # What `finish` asked for: the session to start, or nil.
            session: nil

  @type t :: %__MODULE__{
          step: String.t(),
          answers: %{optional(String.t()) => map()},
          key: String.t() | nil,
          offered: [Catalog.t()],
          suggested: %{String.t() => String.t() | nil},
          check: map() | nil,
          session: map() | nil
        }

  @doc "A flow at its first step."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The step names, in the order a full local setup takes them."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc """
  The two ways a session may treat a tool call, each in two sentences, and the safe
  default first. What the `workspace` step shows.
  """
  @spec approval_choices() :: [%{id: String.t(), label: String.t(), consequence: String.t()}]
  def approval_choices do
    [
      %{
        id: "ask",
        label: "Ask me first",
        consequence:
          "The agent reads freely, and asks before it writes a file or runs a command. " <>
            "You allow once, allow for the session, or deny, and nothing changes on disk until you say so."
      },
      %{
        id: "auto",
        label: "Run everything without asking",
        consequence:
          "Every write and every command runs as soon as the agent asks for it. " <>
            "For a directory whose changes you can afford to throw away, and never for one you cannot."
      }
    ]
  end

  # -- the record -------------------------------------------------------------------

  @doc "Where a finished first run is recorded: beside the sessions, like the identity."
  @spec path(Path.t() | nil) :: Path.t()
  def path(state_dir \\ nil), do: Path.join(Troupe.Paths.state_dir(state_dir), "setup.json")

  @doc "The record of a finished first run, or `nil`."
  @spec completed(Path.t() | nil) :: map() | nil
  def completed(state_dir \\ nil) do
    with {:ok, contents} <- File.read(path(state_dir)),
         {:ok, %{"completed_at" => at} = json} when is_binary(at) <- Jason.decode(contents) do
      Map.take(json, ~w(completed_at choice subject))
    else
      _ -> nil
    end
  end

  @doc "Record that the first run is done, and how it ended."
  @spec record_completed(map(), Path.t() | nil) :: :ok | {:error, String.t()}
  def record_completed(attrs, state_dir \\ nil) do
    file = path(state_dir)

    record = %{
      "completed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "choice" => attrs["choice"] || "local",
      "subject" => attrs["subject"]
    }

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, Jason.encode!(record)) do
      # Nothing secret, but it sits beside the sessions and says who set them up.
      _ = File.chmod(file, 0o600)
      :ok
    else
      {:error, reason} ->
        {:error, "could not write #{Troupe.Paths.display(file)}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Forget that the first run was done, so the next client offers it again."
  @spec forget(Path.t() | nil) :: :ok
  def forget(state_dir \\ nil) do
    File.rm(path(state_dir))
    :ok
  end

  @doc """
  Whether a client should offer the first run: nothing says it was done, there is no
  `config.yaml`, and no model can be asked. A file through which no model can be asked
  is not a first run — its report names the next step — and a refused file is somebody's
  work in progress.
  """
  @spec needed?() :: boolean()
  def needed? do
    completed() == nil and not File.regular?(Config.user_path()) and not usable?()
  end

  defp usable? do
    case Config.resolve(nil) do
      {:ok, config, _layers} -> Config.key_problem(config) == nil
      {:error, _error} -> true
    end
  end

  # -- detection ------------------------------------------------------------------

  @doc """
  What is already on this machine, for the questions to offer: which vendor variables
  are set (names, never values), opencode's providers, the `config.yaml` there is and
  whether a model can be asked through it, and the plane the daemon is linked to.
  """
  @spec detect() :: map()
  def detect do
    file = ModelSettings.describe()
    opencode = OpenCode.providers()

    %{
      "env" => Enum.filter(@vendor_vars, &present?(System.get_env(&1))),
      "opencode" => %{
        "path" => OpenCode.config_path(),
        "providers" => opencode |> Map.keys() |> Enum.sort(),
        "default" => OpenCode.default_model()
      },
      "config" =>
        file
        |> Map.take(~w(exists path provider base_url api_key_set api_key_source models))
        |> Map.put("usable", file["exists"] and usable?()),
      "plane" => plane()
    }
  end

  defp plane do
    case Troupe.Identity.get() do
      nil -> %{"url" => nil, "linked" => false}
      identity -> %{"url" => identity.plane_url, "linked" => true}
    end
  end

  @doc """
  Where a key this flow is given ends up: the user's file, there being no keychain here.
  The path as a person on this platform writes it, since a screen shows it.
  """
  @spec key_storage() :: map()
  def key_storage,
    do: %{"kind" => "file", "path" => Troupe.Paths.display(Config.user_path()), "keychain" => false}

  # -- the report -----------------------------------------------------------------

  @doc """
  The flow as a client sees it: whether a first run is needed and when one was done,
  the step it is at and the steps this path takes, every answer so far (the key as where
  it came from), what the provider listed, the suggestion, the last check and, after
  `finish`, the session asked for.
  """
  @spec report(t()) :: map()
  def report(%__MODULE__{} = flow) do
    %{
      "needed" => needed?(),
      "completed" => completed(),
      "step" => flow.step,
      "steps" =>
        Enum.map(path_of(flow), &%{"name" => &1, "done" => Map.has_key?(flow.answers, &1)}),
      "answers" => flow.answers,
      "detected" => detect(),
      "key_storage" => key_storage(),
      "offered" => Enum.map(flow.offered, &offer_json/1),
      "suggested" => flow.suggested,
      "check" => flow.check,
      "suggested_prompt" => suggested_prompt(get_in(flow.answers, ["workspace", "workspace"])),
      "session" => flow.session
    }
  end

  # The steps this flow takes, given what it has answered: a plane finishes at once, and
  # settings reused from opencode or a file skip the key and the models.
  defp path_of(%__MODULE__{answers: answers}) do
    cond do
      get_in(answers, ["where", "choice"]) == "plane" ->
        ~w(where finish)

      get_in(answers, ["provider", "reuse"]) in ~w(opencode config) ->
        ~w(where provider workspace finish)

      true ->
        @steps
    end
  end

  defp offer_json(%Catalog{} = e) do
    %{
      "id" => e.id,
      "context" => e.context,
      "max_output" => e.max_output,
      "input" => per_million(e.input),
      "output" => per_million(e.output)
    }
  end

  defp per_million(nil), do: nil
  defp per_million(per_token), do: Float.round(per_token * 1_000_000, 4)

  @doc """
  The prompt a first session is offered: a repository is asked to explain itself, and
  any other directory to say what is in it. `nil` until a workspace is chosen.
  """
  @spec suggested_prompt(Path.t() | nil) :: String.t() | nil
  def suggested_prompt(nil), do: nil

  def suggested_prompt(workspace) do
    if File.exists?(Path.join(workspace, ".git")),
      do:
        "Tell me what this project does, how it is built and tested, and where you would start reading.",
      else: "Look around this directory and tell me what you find."
  end

  # -- answering ------------------------------------------------------------------

  @doc """
  Answer one step. The step is the current one, or one already answered, which goes
  back to it; `%{"back" => true}` goes back to a step and takes no answer, for a screen
  whose person wants to see the question again. The answer is checked before anything
  is written, and the reason for a refusal is one sentence a client can show.

  Options: `:subject` — who is answering, recorded when the run finishes.
  """
  @spec answer(t(), String.t(), map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def answer(flow, step, answer, opts \\ [])

  def answer(%__MODULE__{} = flow, step, answer, opts) when is_binary(step) and is_map(answer) do
    cond do
      step not in @steps ->
        {:error, "#{inspect(step)} is not a step; the steps are #{Enum.join(@steps, ", ")}"}

      step != flow.step and not Map.has_key?(flow.answers, step) ->
        {:error, "the current step is #{flow.step}; answer it, or a step already answered"}

      answer["back"] == true ->
        {:ok, back_to(flow, step)}

      true ->
        flow |> back_to(step) |> take(step, answer, opts)
    end
  end

  def answer(%__MODULE__{}, _step, _answer, _opts),
    do: {:error, "step must be a step name and answer an object"}

  # Going back to a step forgets it and everything after it. The key and what the
  # provider listed belong to the key step, so they go with it.
  defp back_to(%__MODULE__{} = flow, step) do
    index = Enum.find_index(@steps, &(&1 == step))
    kept = Map.take(flow.answers, Enum.take(@steps, index))
    flow = %{flow | step: step, answers: kept, session: nil}

    if index <= Enum.find_index(@steps, &(&1 == "key")),
      do: %{
        flow
        | key: nil,
          offered: [],
          suggested: %{"default" => nil, "cheap" => nil},
          check: nil
      },
      else: flow
  end

  defp take(flow, "where", %{"choice" => "local"}, _opts) do
    {:ok, advance(flow, "where", %{"choice" => "local"}, "provider")}
  end

  defp take(flow, "where", %{"choice" => "plane"} = answer, _opts) do
    url = present(answer["plane_url"])
    {:ok, advance(flow, "where", %{"choice" => "plane", "plane_url" => url}, "finish")}
  end

  defp take(_flow, "where", _answer, _opts), do: {:error, "choice must be local or plane"}

  # What is already here: opencode's providers are copied in, and a file that works is
  # kept as it is. Either way the key and the models are answered.
  defp take(flow, "provider", %{"reuse" => "opencode"}, _opts) do
    case ModelSettings.import_opencode() do
      {:ok, %{"imported" => imported}} ->
        answer = %{
          "reuse" => "opencode",
          "providers" => imported["providers"] ++ imported["kept"]
        }

        {:ok, advance(flow, "provider", answer, "workspace")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp take(flow, "provider", %{"reuse" => "config"}, _opts) do
    if File.regular?(Config.user_path()) and usable?() do
      answer = %{"reuse" => "config", "path" => Config.user_path()}
      {:ok, advance(flow, "provider", answer, "workspace")}
    else
      {:error,
       "there is no config.yaml through which a model can be asked; set a provider up instead"}
    end
  end

  defp take(_flow, "provider", %{"reuse" => other}, _opts),
    do: {:error, "reuse must be opencode or config, not #{inspect(other)}"}

  defp take(flow, "provider", answer, _opts) do
    with {:ok, provider} <- provider(answer["provider"]),
         {:ok, kind} <- kind(answer["kind"], provider),
         {:ok, base_url} <- base_url(answer["base_url"], provider, kind),
         {:ok, auth} <- auth(answer["auth"]) do
      accepted = %{"provider" => provider, "kind" => kind, "base_url" => base_url, "auth" => auth}
      {:ok, advance(flow, "provider", accepted, "key")}
    end
  end

  defp take(flow, "key", answer, _opts) do
    with {:ok, key, source} <- key_of(answer, flow.answers["provider"]) do
      check(flow, key, source)
    end
  end

  defp take(flow, "models", answer, _opts) do
    with {:ok, default} <- model_id(answer["default"], "default"),
         {:ok, cheap} <- optional_model_id(answer["cheap"]),
         {:ok, _saved} <- write_settings(flow.answers["provider"], flow.key, default, cheap) do
      {:ok, advance(flow, "models", %{"default" => default, "cheap" => cheap}, "workspace")}
    end
  end

  defp take(flow, "workspace", answer, _opts) do
    with {:ok, workspace} <- directory(answer["workspace"]),
         {:ok, approvals} <- approvals(answer["approvals"]),
         {:ok, _path} <-
           Config.write_key(Config.user_path(), ["auto_approve"], approvals == "auto") do
      {:ok,
       advance(flow, "workspace", %{"workspace" => workspace, "approvals" => approvals}, "finish")}
    end
  end

  defp take(flow, "finish", answer, opts) do
    choice = get_in(flow.answers, ["where", "choice"]) || "local"

    with :ok <- record_completed(%{"choice" => choice, "subject" => Keyword.get(opts, :subject)}) do
      session = first_session(choice, answer, get_in(flow.answers, ["workspace", "workspace"]))
      {:ok, %{advance(flow, "finish", %{"start" => session != nil}, "done") | session: session}}
    end
  end

  # A local setup ends in a session unless told not to; a plane's is the client's to open.
  defp first_session("local", answer, workspace) when is_binary(workspace) do
    if answer["start"] == false,
      do: nil,
      else: %{
        "workspace" => workspace,
        "prompt" => present(answer["prompt"]) || suggested_prompt(workspace)
      }
  end

  defp first_session(_choice, _answer, _workspace), do: nil

  defp advance(flow, step, answer, next),
    do: %{flow | answers: Map.put(flow.answers, step, answer), step: next}

  # -- the key check --------------------------------------------------------------

  # A pasted key is checked as typed; one from the environment is read and checked, and
  # written as the reference, so the file never holds it. A gateway may want none.
  defp key_of(%{"api_key" => key}, provider) when is_binary(key) do
    case {present(key), Regex.run(@env_reference, String.trim(key))} do
      {nil, _} -> {:error, "api_key is empty; paste the key, or name the variable it is in"}
      {_, [_, var]} -> key_of(%{"env" => var}, provider)
      {key, nil} -> {:ok, key, %{"source" => "typed"}}
    end
  end

  defp key_of(%{"env" => var}, _provider) when is_binary(var) do
    cond do
      not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, var) ->
        {:error, "#{inspect(var)} is not a variable name"}

      not present?(System.get_env(var)) ->
        {:error,
         "#{var} is not set where the daemon runs; paste the key, or set it and start the daemon again"}

      true ->
        {:ok, "{env:#{var}}", %{"source" => "env", "var" => var}}
    end
  end

  defp key_of(_answer, %{"provider" => provider, "base_url" => base_url}) do
    case {provider, Endpoint.vendor_key_var(provider, base_url)} do
      {"fake", _var} -> {:ok, nil, %{"source" => "none"}}
      {_provider, nil} -> {:ok, nil, %{"source" => "none"}}
      {_provider, var} -> {:error, "#{provider} needs a key; paste one, or keep it in #{var}"}
    end
  end

  defp key_of(_answer, _provider), do: {:error, "answer the provider step first"}

  defp check(flow, key, source) do
    provider = flow.answers["provider"]

    params = %{
      "provider" => provider["provider"],
      "base_url" => provider["base_url"],
      "api_key" => key && Config.interpolate(key),
      "auth" => provider["auth"]
    }

    case check_key(params) do
      {:ok, offered} ->
        {:ok, checked(flow, key, source, offered, %{"state" => "ok", "reason" => nil})}

      {:refused, reason} ->
        {:ok, %{flow | check: %{"state" => "refused", "reason" => reason}}}

      {:unknown, reason} ->
        {:ok, checked(flow, key, source, [], %{"state" => "unknown", "reason" => reason})}
    end
  end

  defp checked(flow, key, source, offered, check) do
    %{
      advance(flow, "key", source, "models")
      | key: key,
        offered: offered,
        suggested: suggest(flow.answers["provider"]["provider"], offered),
        check: check
    }
  end

  @doc """
  Try a key against its provider with a real request — the model listing, which every
  provider authenticates — and say what came back: the models, `refused` for a key the
  provider turned away, or `unknown` when the provider answered with anything else, or
  not at all, since a gateway with no listing may still take the key.

  The `fake` provider asks nobody: any key is accepted and lists two models, and one
  beginning `bad` is refused, so a client's refused path can be driven with no model
  behind it.
  """
  @spec check_key(map()) :: {:ok, [Catalog.t()]} | {:refused, String.t()} | {:unknown, String.t()}
  def check_key(%{"provider" => "fake"} = params) do
    if String.starts_with?(params["api_key"] || "", "bad"),
      do: {:refused, "401 unauthorized: the key was refused"},
      else: {:ok, fake_models()}
  end

  def check_key(%{"provider" => provider} = params) do
    config = %Config{
      provider: provider,
      base_url: present(params["base_url"]),
      api_key: present(params["api_key"]),
      auth: if(params["auth"] == "bearer", do: :bearer, else: :api_key),
      providers: %{}
    }

    case Store.discover(config) do
      {[_ | _] = offered, _failures} ->
        {:ok, Enum.sort_by(offered, & &1.id)}

      {[], [{_name, {:http, status} = reason} | _]} when status in [401, 403] ->
        {:refused, ModelSettings.describe_failure(reason)}

      {[], [{_name, reason} | _]} ->
        {:unknown, ModelSettings.describe_failure(reason)}

      {[], []} ->
        {:unknown,
         if(config.api_key,
           do: "the provider listed no models",
           else: "no key was given, so nothing was asked"
         )}
    end
  end

  defp fake_models do
    [
      %Catalog{id: "fake-model", context: 200_000, max_output: 8_192},
      %Catalog{id: "fake-small", context: 200_000, max_output: 8_192}
    ]
  end

  @doc """
  A safe answer to the models step: the main model is the newest of the family a
  person would pick first, the small one the newest of the cheap family, and each
  falls back to the first thing listed — or, for Anthropic with nothing listed, the
  model Troupe uses when nothing names one.
  """
  @spec suggest(String.t(), [Catalog.t()]) :: %{String.t() => String.t() | nil}
  def suggest(provider, offered) do
    ids = Enum.map(offered, & &1.id)

    default =
      pick(ids, ~w(claude-sonnet claude-opus gpt-5 fake-model)) || List.first(ids) ||
        if(provider == "anthropic", do: %Config{}.model)

    cheap = pick(ids, ~w(claude-haiku mini small flash lite)) || default
    %{"default" => default, "cheap" => cheap}
  end

  # The first family with a member, and its newest member: ids sort by version.
  defp pick(ids, families) do
    Enum.find_value(families, fn family ->
      case Enum.filter(ids, &String.contains?(String.downcase(&1), family)) do
        [] -> nil
        members -> Enum.max(members)
      end
    end)
  end

  # -- writing --------------------------------------------------------------------

  # Through the writer the settings screen uses: the same spellings, the same `.previous`.
  # No key removes a saved one, so a gateway that wants none is not sent the last key.
  defp write_settings(provider, key, default, cheap) do
    ModelSettings.write(%{
      "provider" => provider["provider"],
      "base_url" => provider["base_url"],
      "auth" => provider["auth"],
      "api_key" => key || "",
      "models" => %{"default" => default, "cheap" => cheap}
    })
  end

  # -- validation -----------------------------------------------------------------

  defp provider(value) when value in @providers, do: {:ok, value}

  defp provider(value),
    do: {:error, "provider must be one of #{Enum.join(@providers, ", ")}, not #{inspect(value)}"}

  defp kind(nil, provider), do: {:ok, provider}
  defp kind(kind, "fake"), do: {:ok, kind}
  defp kind(kind, _provider) when kind in @kinds, do: {:ok, kind}

  defp kind(kind, _provider),
    do: {:error, "kind must be one of #{Enum.join(@kinds, ", ")}, not #{inspect(kind)}"}

  # A gateway is its URL; the vendors have their own, and nothing means that one.
  defp base_url(url, provider, kind) do
    case present(url) do
      nil when kind in ~w(gateway litellm) ->
        {:error, "a #{kind} needs its base URL, ending in /v1"}

      nil ->
        {:ok, nil}

      url when provider == "fake" ->
        {:ok, url}

      url ->
        if URI.parse(url).host == nil,
          do: {:error, "#{inspect(url)} is not a URL"},
          else: {:ok, url}
    end
  end

  defp auth(nil), do: {:ok, "api_key"}
  defp auth(value) when value in ~w(api_key bearer), do: {:ok, value}
  defp auth(value), do: {:error, "auth must be api_key or bearer, not #{inspect(value)}"}

  defp model_id(value, role) do
    case present(value) do
      nil -> {:error, "#{role} must be a model id"}
      id -> {:ok, id}
    end
  end

  defp optional_model_id(nil), do: {:ok, nil}
  defp optional_model_id(value) when is_binary(value), do: {:ok, present(value)}
  defp optional_model_id(_value), do: {:error, "cheap must be a model id or null"}

  defp directory(value) do
    with path when is_binary(path) <- present(value),
         expanded = Path.expand(path),
         true <- File.dir?(expanded) do
      {:ok, expanded}
    else
      nil -> {:error, "workspace must be a directory"}
      false -> {:error, "#{Troupe.Paths.display(Path.expand(value))} is not a directory"}
    end
  end

  defp approvals(nil), do: {:ok, "ask"}
  defp approvals(value) when value in @approvals, do: {:ok, value}
  defp approvals(value), do: {:error, "approvals must be ask or auto, not #{inspect(value)}"}

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
