defmodule Troupe.UI.Setup do
  @moduledoc """
  `troupe setup`: a first run's questions as one screen (TUI Decision 153, root Decision
  817). It walks the daemon's own flow (`setup.get`, `setup.answer`; root Decision 705), so
  it asks what the desktop app's first run asks, in that order and in those words: where
  the work runs, the provider, its key, the models, a first project and what the agent may
  do there without asking, whether the daemon starts at login, and a summary.

  Nothing is written before the summary. `where`, `provider` and `key` write nothing, so
  they go to the daemon as they are answered and its answer is on the screen before the
  next question: the key checked with a real request, the models the provider serves.
  `models`, `workspace`, `daemon` and `finish` write the settings file, the login entry and
  the record that the first run is done (and so does copying opencode's providers in), so
  they are held here and sent in order once the summary is confirmed. Esc leaves before
  that with nothing written, and the daemon forgets the key it was given.

  Shift-Tab goes back a step: on this screen for an answer held here, and on the daemon too
  (`{"back": true}`) for one it holds, which forgets what came after, the key included.

  It holds no socket of its own: `call` is how it asks the daemon, which `troupe setup`
  gives it (`Troupe.CLI.ConfigSetup`) and a test plays. `on_done` is told how it ended:
  `{:session, id, workspace}`, `{:no_session, reason}`, `{:plane, url}`, or `{:left,
  wrote?}`, `wrote?` being whether a confirmed summary had written anything before a step
  was refused.
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Troupe.UI.TUI.{Input, Model, Theme}

  @steps ~w(where provider key models workspace daemon finish)

  # The desktop app's names for the steps (`Step.tsx`), for the row of steps on top.
  @words %{
    "where" => "Where",
    "provider" => "Provider",
    "key" => "Key",
    "models" => "Models",
    "workspace" => "Project",
    "daemon" => "At login",
    "finish" => "First session"
  }

  # A login entry as a person on that platform would recognise it (`Daemon.tsx`).
  @entries %{
    "startup_folder" =>
      "an entry in your Startup folder, which runs it in a console window minimised to the taskbar; closing that window stops it",
    "launch_agent" => "a launchd agent in your LaunchAgents folder",
    "systemd" => "a systemd user unit",
    "autostart" => "an autostart entry, which your desktop session starts"
  }

  @type outcome ::
          {:session, String.t(), String.t()}
          | {:no_session, String.t()}
          | {:plane, String.t() | nil}
          | {:left, boolean()}

  ## ExRatatui.App

  @impl true
  def mount(opts) do
    call = Keyword.fetch!(opts, :call)

    state = %{
      call: call,
      on_done: Keyword.get(opts, :on_done, fn _outcome -> :ok end),
      # Where `troupe` was started: the first project it offers, and what a relative
      # directory is read from.
      here: Keyword.get(opts, :workspace) || File.cwd!(),
      offer_fake: Keyword.get(opts, :offer_fake, false),
      theme: Keyword.get(opts, :theme) || Theme.current(),
      flow: nil,
      step: "where",
      part: :main,
      cursor: 0,
      input: {"", 0},
      main: nil,
      held: %{},
      sent: %{},
      said: nil,
      error: nil,
      busy: nil,
      wrote: false
    }

    case first_flow(call, Keyword.get(opts, :flow)) do
      {:ok, flow} -> {:ok, enter(%{state | flow: flow}, flow["step"])}
      {:error, reason} -> {:error, reason}
    end
  end

  # A flow another client left half-way is begun again from the top, and the daemon
  # forgets a key it was given there.
  defp first_flow(call, nil) do
    case call.("setup.get", %{}) do
      {:ok, flow} -> first_flow(call, flow)
      error -> error
    end
  end

  defp first_flow(_call, %{"answers" => answers} = flow) when answers == %{}, do: {:ok, flow}
  defp first_flow(call, _flow), do: call.("setup.answer", params("where", %{"back" => true}))

  @impl true
  def render(state, frame) do
    state |> draw(frame) |> Theme.paint(state.theme)
  end

  @impl true
  def handle_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  # A question is out to the daemon: nothing is taken until it answers.
  def handle_event(_event, %{busy: busy} = state) when busy != nil,
    do: {:noreply, state, render?: false}

  def handle_event(%Key{code: "esc"}, state), do: leave(state)
  def handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state), do: leave(state)
  def handle_event(%Key{code: "back_tab"}, state), do: {:noreply, back(state)}
  def handle_event(%Key{code: "enter"}, state), do: submit(state)
  def handle_event(%Key{code: "up"}, state), do: {:noreply, move(state, -1)}
  def handle_event(%Key{code: "down"}, state), do: {:noreply, move(state, 1)}

  def handle_event(%Paste{content: content}, state) do
    line = content |> String.split(["\r\n", "\n", "\r"]) |> List.first() |> String.trim()
    {:noreply, if(field(state), do: %{state | input: Input.insert(state.input, line)}, else: state)}
  end

  def handle_event(%Key{} = key, state), do: {:noreply, edit(state, key)}
  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info({__MODULE__, tag, result}, state), do: answered(tag, result, %{state | busy: nil})
  # A frame on demand, as the session's window draws one (`TUIHelpers.screen/2`).
  def handle_info(:force_render, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state, render?: false}

  ## Moving through the steps

  # Each step opens with the answer it had, or the safe one, under the cursor.
  defp enter(state, step) do
    state = %{state | step: step, part: :main, main: nil, error: nil, input: {"", 0}}

    case step do
      "where" -> where_defaults(state)
      "provider" -> provider_defaults(state)
      "key" -> key_defaults(state)
      "models" -> models_defaults(state)
      "workspace" -> workspace_defaults(state)
      "daemon" -> daemon_defaults(state)
      "finish" -> finish_defaults(state)
    end
  end

  defp move(state, by) do
    case choices(state) do
      [] -> state
      list -> %{state | cursor: state.cursor |> Kernel.+(by) |> max(0) |> min(length(list) - 1)}
    end
  end

  defp edit(state, key) do
    with %{} <- field(state),
         :pass <- Input.key(key, state.input) do
      if printable?(key), do: %{state | input: Input.insert(state.input, key.code)}, else: state
    else
      nil -> state
      {:ok, input} -> %{state | input: input}
    end
  end

  defp printable?(%Key{code: code, modifiers: mods}),
    do: mods in [[], ["shift"]] and String.length(code) == 1

  defp text(state), do: state.input |> elem(0) |> String.trim()

  defp put_text(state, nil), do: %{state | input: {"", 0}}
  defp put_text(state, text), do: %{state | input: {text, String.length(text)}}

  defp selected(state), do: Enum.at(choices(state), state.cursor)

  # The text field the selected choice asks for, or the step's own.
  defp field(%{step: "workspace"}), do: %{label: "directory", secret?: false}
  defp field(%{step: "finish"} = state), do: if(plane?(state), do: nil, else: prompt_field())
  defp field(state), do: state |> selected() |> then(&(&1 && &1[:field]))

  defp prompt_field,
    do: %{
      label: "what to ask first (Enter alone: the suggestion for this directory)",
      secret?: false
    }

  ## Answering

  defp submit(%{step: "where"} = state) do
    case selected(state).id do
      "local" ->
        {:noreply, send_step(state, "where", %{"choice" => "local"})}

      "plane" ->
        case text(state) do
          "" ->
            {:noreply,
             %{state | error: "the plane's address is needed: troupe login signs in there"}}

          url ->
            {:noreply, send_step(state, "where", %{"choice" => "plane", "plane_url" => url})}
        end
    end
  end

  # Copying opencode's providers in writes the settings file, so it waits for the summary
  # like the other answers that write; everything else here is the daemon's at once.
  defp submit(%{step: "provider"} = state) do
    choice = selected(state)

    case choice.answer do
      %{"reuse" => "opencode"} = answer ->
        {:noreply, enter(%{state | held: Map.put(state.held, "provider", answer)}, "workspace")}

      answer ->
        answer = if choice[:field], do: Map.put(answer, "base_url", text(state)), else: answer
        state = %{state | held: Map.delete(state.held, "provider")}
        {:noreply, send_step(state, "provider", answer)}
    end
  end

  # A typed key leaves this screen the moment it is sent: the daemon keeps it for the step
  # that writes it, and it is never drawn, said or held here (Decision 705).
  defp submit(%{step: "key"} = state) do
    case {selected(state).id, text(state)} do
      {{:env, var}, _} ->
        {:noreply, send_step(state, "key", %{"env" => var})}

      {:typed, ""} ->
        {:noreply, %{state | error: "paste the key, or name the variable it is in as {env:VAR}"}}

      {:typed, key} ->
        {:noreply, send_step(put_text(state, nil), "key", %{"api_key" => key})}

      {:none, _} ->
        {:noreply, send_step(state, "key", %{})}
    end
  end

  defp submit(%{step: "models", part: :main} = state) do
    case model_choice(state) do
      nil ->
        {:noreply, %{state | error: "type the id the provider knows the model by"}}

      id ->
        state = %{state | main: id, part: :small, error: nil, input: {"", 0}}
        {:noreply, small_defaults(state)}
    end
  end

  defp submit(%{step: "models", part: :small} = state) do
    cheap =
      case selected(state).id do
        :same -> nil
        _other -> model_choice(state)
      end

    models = %{"default" => state.main, "cheap" => cheap}
    {:noreply, enter(%{state | held: Map.put(state.held, "models", models)}, "workspace")}
  end

  defp submit(%{step: "workspace"} = state) do
    dir = Path.expand(text(state), state.here)

    if text(state) != "" and File.dir?(dir) do
      answer = %{"workspace" => dir, "approvals" => selected(state).id}
      {:noreply, enter(%{state | held: Map.put(state.held, "workspace", answer)}, "daemon")}
    else
      {:noreply, %{state | error: "#{dir} is not a directory"}}
    end
  end

  defp submit(%{step: "daemon"} = state) do
    choice = selected(state)

    if choice[:off] do
      {:noreply, %{state | error: choice.off}}
    else
      held = Map.put(state.held, "daemon", %{"at_login" => choice.id})
      {:noreply, enter(%{state | held: held}, "finish")}
    end
  end

  # The summary confirmed: everything held is sent, in the flow's order.
  defp submit(%{step: "finish"} = state) do
    answer =
      cond do
        plane?(state) -> %{}
        text(state) == "" -> %{"start" => true}
        true -> %{"start" => true, "prompt" => text(state)}
      end

    state = %{state | held: Map.put(state.held, "finish", answer)}
    sends = to_send(state)
    call = state.call
    {:noreply, ask(state, "saving and starting…", :confirm, fn -> send_all(call, sends) end)}
  end

  defp model_choice(state) do
    case selected(state).id do
      :typed -> if text(state) == "", do: nil, else: text(state)
      id -> id
    end
  end

  defp send_step(state, step, answer) do
    call = state.call

    ask(state, asking(state, step), {:answer, step}, fn ->
      call.("setup.answer", params(step, answer))
    end)
  end

  defp asking(state, "key"),
    do: "asking #{provider_name(provider(state))} whether it takes the key…"

  defp asking(_state, _step), do: "asking the daemon…"

  # The answers held here that the daemon has not taken as they stand, in the flow's
  # order: from the first one it lacks, or that changed since it took it, to `finish`.
  # Answering a step again goes back to it, so everything after it is sent again too.
  defp to_send(state) do
    path = path(state)

    first =
      Enum.find_index(path, fn step ->
        Map.has_key?(state.held, step) and
          (not Map.has_key?(state.flow["answers"], step) or state.sent[step] != state.held[step])
      end)

    path
    |> Enum.drop(first || length(path))
    |> Enum.filter(&Map.has_key?(state.held, &1))
    |> Enum.map(&{&1, state.held[&1]})
  end

  # One after the other, stopping at the first refusal, which comes back with the flow
  # as the daemon then has it.
  defp send_all(call, sends) do
    Enum.reduce_while(sends, {:ok, nil, []}, fn {step, answer}, {:ok, _flow, sent} ->
      case call.("setup.answer", params(step, answer)) do
        {:ok, flow} ->
          {:cont, {:ok, flow, [{step, answer} | sent]}}

        {:error, reason} ->
          {:halt, {:error, step, reason, now(call), sent}}
      end
    end)
  end

  defp now(call) do
    case call.("setup.get", %{}) do
      {:ok, flow} -> flow
      {:error, _reason} -> nil
    end
  end

  defp ask(state, busy, tag, fun) do
    me = self()

    Task.start(fn ->
      result =
        try do
          fun.()
        rescue
          error -> {:error, Exception.message(error)}
        catch
          :exit, reason -> {:error, Exception.format_exit(reason)}
        end

      send(me, {__MODULE__, tag, result})
    end)

    %{state | busy: busy, error: nil}
  end

  defp params(step, answer),
    do: %{"step" => step, "answer" => answer, "command_id" => command_id()}

  defp command_id,
    do: "setup-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  ## What the daemon said

  # A key the provider refused keeps the step, and says why.
  defp answered({:answer, "key"}, {:ok, %{"step" => "key"} = flow}, state) do
    {:noreply, %{enter(%{state | flow: flow}, "key") | error: check_words(flow["check"])}}
  end

  defp answered({:answer, step}, {:ok, flow}, state) do
    state = %{state | flow: flow, said: said(step, flow)}
    {:noreply, enter(state, flow["step"])}
  end

  defp answered({:back, step}, {:ok, flow}, state),
    do: {:noreply, enter(%{state | flow: flow, said: nil}, step)}

  defp answered(:confirm, {:ok, flow, _sent}, state), do: done(state, outcome(flow))

  defp answered(:confirm, {:error, step, reason, flow, sent}, state) do
    state = %{
      state
      | flow: flow || state.flow,
        sent: Map.merge(state.sent, Map.new(sent)),
        wrote: state.wrote or sent != []
    }

    {:noreply, %{enter(state, step) | error: refusal(reason)}}
  end

  defp answered(:leave, _result, state), do: done(state, {:left, state.wrote})

  defp answered(_tag, {:error, reason}, state), do: {:noreply, %{state | error: refusal(reason)}}

  defp said("where", %{"answers" => %{"where" => %{"choice" => "plane"}}}), do: nil
  defp said("where", _flow), do: "This computer, with a key of your own."

  defp said("provider", %{"answers" => %{"provider" => %{"reuse" => "config"}}} = flow),
    do: "#{flow["detected"]["config"]["path"]} is kept as it is."

  defp said("provider", flow), do: provider_words(flow["answers"]["provider"]) <> "."
  defp said("key", flow), do: check_words(flow["check"])

  defp check_words(%{"state" => "ok"}), do: "The provider accepted the key."

  defp check_words(%{"state" => "refused", "reason" => reason}),
    do: "The provider refused the key: #{reason || "no reason given"}. Check it and try again."

  defp check_words(%{"state" => "unknown", "reason" => reason}),
    do:
      "The key could not be confirmed: #{reason || "the provider did not answer"}. You can go on and type a model id."

  defp check_words(_check), do: nil

  # The daemon says a refusal as `invalid_params: <one sentence>`; the sentence is it.
  defp refusal("invalid_params: " <> reason), do: reason
  defp refusal(reason) when is_binary(reason), do: reason
  defp refusal(%{"message" => message}), do: message
  defp refusal(reason), do: inspect(reason)

  defp outcome(%{"answers" => %{"where" => %{"choice" => "plane"} = where}}),
    do: {:plane, where["plane_url"]}

  defp outcome(%{"session" => %{"session_id" => id} = session}),
    do: {:session, id, session["workspace"]}

  defp outcome(%{"session" => %{"error" => reason}}), do: {:no_session, reason}
  defp outcome(_flow), do: {:no_session, "the daemon started no session"}

  defp done(state, outcome) do
    state.on_done.(outcome)
    {:stop, state}
  end

  # Leaving writes nothing; the daemon is asked to forget what it was told, a key with it.
  defp leave(%{flow: %{"answers" => answers}} = state) when answers == %{},
    do: done(state, {:left, state.wrote})

  defp leave(state) do
    call = state.call

    {:noreply,
     ask(state, "leaving…", :leave, fn ->
       call.("setup.answer", params("where", %{"back" => true}))
     end)}
  end

  ## Going back

  defp back(%{step: "models", part: :small} = state),
    do: models_defaults(%{state | part: :main, error: nil, input: {"", 0}})

  defp back(state) do
    path = path(state)

    case Enum.find_index(path, &(&1 == state.step)) do
      index when index in [nil, 0] ->
        state

      index ->
        target = Enum.at(path, index - 1)
        call = state.call

        if Map.has_key?(state.flow["answers"], target),
          do:
            ask(state, "going back…", {:back, target}, fn ->
              call.("setup.answer", params(target, %{"back" => true}))
            end),
          else: enter(state, target)
    end
  end

  # The steps this run takes: a plane finishes at once, and settings reused from opencode
  # or a `config.yaml` skip the key and the models, as the daemon's flow does.
  defp path(state) do
    cond do
      plane?(state) -> ~w(where finish)
      provider(state)["reuse"] in ~w(opencode config) -> ~w(where provider workspace daemon finish)
      true -> @steps
    end
  end

  defp plane?(state), do: get_in(state.flow, ["answers", "where", "choice"]) == "plane"

  # The provider as answered: held here (opencode's copy) or taken by the daemon.
  defp provider(state),
    do: state.held["provider"] || get_in(state.flow, ["answers", "provider"]) || %{}

  ## The steps

  defp choices(%{step: "where"}) do
    [
      %{
        id: "local",
        label: "Use my own machine and keys",
        note:
          "Sessions run in the daemon on this computer, against a model provider you give it a key for. The one thing that leaves the machine is the call to that provider."
      },
      %{
        id: "plane",
        label: "Sign in to my organisation's Troupe",
        note:
          "Your team's plane runs the sessions and provides the models. You sign in where you always do, and Troupe never holds a password of its own.",
        field: %{label: "the plane's address", secret?: false}
      }
    ]
  end

  # What is already on the machine first: the shortest first run reuses it.
  defp choices(%{step: "provider"} = state) do
    detected = state.flow["detected"]
    already = env_choices(detected) ++ opencode_choice(detected) ++ config_choice(detected)
    url = %{label: "the address, ending in /v1", secret?: false}

    kinds = [
      %{
        id: "anthropic",
        label: "Anthropic",
        note: "Claude, at Anthropic's own endpoint, with a key from console.anthropic.com.",
        answer: %{"provider" => "anthropic", "kind" => "anthropic"}
      },
      %{
        id: "openai",
        label: "OpenAI",
        note: "GPT, at OpenAI's own endpoint, with a key from platform.openai.com.",
        answer: %{"provider" => "openai", "kind" => "openai"}
      },
      %{
        id: "gateway",
        label: "An OpenAI-compatible gateway",
        note:
          "Anything speaking Chat Completions at a URL of yours: vLLM, OpenRouter, a company gateway. Some want no key.",
        answer: %{"provider" => "openai", "kind" => "gateway"},
        field: url
      },
      %{
        id: "litellm",
        label: "A LiteLLM proxy",
        note: "A LiteLLM proxy at its URL. The one gateway that says what each model costs.",
        answer: %{"provider" => "openai", "kind" => "litellm"},
        field: url
      }
    ]

    # The scripted provider, offered only where someone set a script up for it.
    fake =
      if state.offer_fake,
        do: [
          %{
            id: "fake",
            label: "The fake provider",
            note:
              "Scripted replies from the file TROUPE_FAKE_SCRIPT names, not a model: nothing is sent anywhere.",
            answer: %{"provider" => "fake"}
          }
        ],
        else: []

    already ++ kinds ++ fake
  end

  defp choices(%{step: "key"} = state) do
    provider = provider(state)
    var = Troupe.Config.vendor_key_var(provider["provider"], provider["base_url"])
    name = provider_name(provider)

    env =
      if var && var in state.flow["detected"]["env"],
        do: [
          %{
            id: {:env, var},
            label: "Keep it in #{var}",
            note:
              "The settings refer to the variable and never hold the key. Set it wherever the daemon starts."
          }
        ],
        else: []

    typed = %{
      id: :typed,
      label: "Paste it",
      note:
        "Saved into the settings file, and sent only to #{name}. {env:VAR} instead keeps it in a variable the settings refer to.",
      field: %{label: "API key, or {env:VAR} to read it from the environment", secret?: true}
    }

    none =
      cond do
        provider["provider"] == "fake" ->
          [%{id: :none, label: "The fake provider needs no key", note: "Nothing is sent anywhere."}]

        var == nil ->
          [
            %{
              id: :none,
              label: "This gateway needs no key",
              note: "Nothing is sent. A gateway on your own machine or network often wants none."
            }
          ]

        true ->
          []
      end

    env ++ [typed] ++ none
  end

  defp choices(%{step: "models", part: part} = state) do
    suggested = state.flow["suggested"] || %{}
    mark = if part == :main, do: suggested["default"], else: suggested["cheap"]

    offered =
      Enum.map(state.flow["offered"] || [], fn offer ->
        %{
          id: offer["id"],
          label: offer["id"] <> if(offer["id"] == mark, do: " · suggested", else: ""),
          note: describe_offer(offer)
        }
      end)

    typed = %{
      id: :typed,
      label: if(offered == [], do: "type the model id", else: "type one instead…"),
      note: if(offered == [], do: "The id the provider knows the model by."),
      field: %{label: "model id", secret?: false}
    }

    same =
      if part == :small,
        do: [%{id: :same, label: "the same as the main model (#{state.main})", note: nil}],
        else: []

    same ++ offered ++ [typed]
  end

  defp choices(%{step: "workspace"}) do
    [
      %{
        id: "ask",
        label: "Ask me first · default",
        note:
          "The agent reads freely, and asks before it writes a file or runs a command. You allow once, allow for the session, or deny, and nothing changes on disk until you say so."
      },
      %{
        id: "auto",
        label: "Run everything without asking",
        note:
          "Every write and every command runs as soon as the agent asks for it. For a directory whose changes you can afford to throw away, and never for one you cannot."
      }
    ]
  end

  # An entry that is there already is kept, not asked about, as the installers do (root
  # Decision 818): the answer is the state, and `troupe daemon login off` takes it back.
  defp choices(%{step: "daemon", flow: %{"daemon" => %{"at_login" => true} = status}}) do
    [
      %{
        id: true,
        label: "It starts when you log in, and that is kept",
        note: "From #{status["path"]}. troupe daemon login off takes it back, from a terminal."
      }
    ]
  end

  defp choices(%{step: "daemon"} = state) do
    status = state.flow["daemon"] || %{}

    on =
      if status["command"],
        do: %{
          id: true,
          label: "Start it when I log in",
          note:
            "Adds #{@entries[status["kind"]] || "a login entry"}. It starts #{status["command"]} from your next login; nothing starts now."
        },
        else: %{
          id: true,
          label: "Start it when I log in",
          note: nil,
          off:
            "troupe-daemon is not on this computer's PATH, so there is nothing to start. Install it, then run troupe setup again."
        }

    [
      %{
        id: false,
        label: "Only when an app needs it · default",
        note: "Nothing is added to what starts when you log in."
      },
      on
    ]
  end

  defp choices(%{step: "finish"}), do: []

  defp env_choices(detected) do
    for {var, provider, name} <- [
          {"ANTHROPIC_API_KEY", "anthropic", "Anthropic"},
          {"OPENAI_API_KEY", "openai", "OpenAI"}
        ],
        var in (detected["env"] || []) do
      %{
        id: {:env, var},
        label: "#{var} is set on this computer",
        note:
          "Use #{name} with that key. It stays in the environment; the settings only refer to it.",
        answer: %{"provider" => provider, "kind" => provider}
      }
    end
  end

  defp opencode_choice(%{"opencode" => %{"providers" => [_ | _] = providers} = opencode}) do
    start = if opencode["default"], do: ", and start from #{opencode["default"]}", else: ""

    [
      %{
        id: :opencode,
        label: "opencode is set up here, with #{Enum.join(providers, ", ")}",
        note:
          "Copy its providers into Troupe's settings, keys as opencode has them written#{start}.",
        answer: %{"reuse" => "opencode"}
      }
    ]
  end

  defp opencode_choice(_detected), do: []

  defp config_choice(%{"config" => %{"usable" => true} = config}) do
    which = if config["provider"], do: " (#{config["provider"]})", else: ""

    [
      %{
        id: :config,
        label: "A working config.yaml#{which}",
        note: "Keep #{config["path"]} as it is and go straight to the first project.",
        answer: %{"reuse" => "config"}
      }
    ]
  end

  defp config_choice(_detected), do: []

  ## Where each step starts

  defp where_defaults(state) do
    where = get_in(state.flow, ["answers", "where"]) || %{}
    url = where["plane_url"] || get_in(state.flow, ["detected", "plane", "url"])
    %{put_text(state, url) | cursor: if(where["choice"] == "plane", do: 1, else: 0)}
  end

  defp provider_defaults(state) do
    earlier = provider(state)
    list = choices(state)

    index =
      Enum.find_index(list, fn choice ->
        (earlier["reuse"] && choice.answer["reuse"] == earlier["reuse"]) ||
          (earlier["kind"] && choice.id == earlier["kind"])
      end)

    %{put_text(state, earlier["base_url"]) | cursor: index || 0}
  end

  defp key_defaults(state) do
    list = choices(state)
    env = Enum.find_index(list, &match?({:env, _}, &1.id))
    none = Enum.find_index(list, &(&1.id == :none))
    typed = Enum.find_index(list, &(&1.id == :typed))
    fake? = provider(state)["provider"] == "fake"
    %{state | cursor: env || if(fake?, do: none, else: typed) || 0}
  end

  defp models_defaults(state) do
    earlier = state.held["models"] || %{}
    want = state.main || earlier["default"] || get_in(state.flow, ["suggested", "default"])
    pick(state, want)
  end

  defp small_defaults(state) do
    earlier = state.held["models"]

    want =
      if earlier && earlier["default"] == state.main,
        do: earlier["cheap"] || :same,
        else: get_in(state.flow, ["suggested", "cheap"])

    pick(state, if(want in [nil, state.main], do: :same, else: want))
  end

  # The cursor on a model the list has, or on typing it, with the id already typed.
  defp pick(state, want) do
    list = choices(state)

    case Enum.find_index(list, &(&1.id == want)) do
      nil when is_binary(want) -> %{put_text(state, want) | cursor: length(list) - 1}
      nil -> %{state | cursor: 0}
      index -> %{state | cursor: index}
    end
  end

  defp workspace_defaults(state) do
    earlier = state.held["workspace"] || %{}
    state = put_text(state, earlier["workspace"] || state.here)
    %{state | cursor: if(earlier["approvals"] == "auto", do: 1, else: 0)}
  end

  defp daemon_defaults(state) do
    at_login =
      case state.held["daemon"] do
        %{"at_login" => on} -> on
        nil -> get_in(state.flow, ["daemon", "at_login"]) == true
      end

    %{state | cursor: Enum.find_index(choices(state), &(&1.id == at_login)) || 0}
  end

  defp finish_defaults(state) do
    put_text(state, get_in(state.held, ["finish", "prompt"]))
  end

  ## Words

  defp provider_name(%{"provider" => "anthropic", "base_url" => nil}), do: "Anthropic"
  defp provider_name(%{"provider" => "openai", "base_url" => nil}), do: "OpenAI"
  defp provider_name(%{"provider" => "fake"}), do: "the fake provider"
  defp provider_name(_provider), do: "the gateway"

  # A provider as the choice the person made named it: a gateway is not "openai" to them.
  defp provider_words(%{"reuse" => "opencode"}), do: "opencode's providers, copied in"
  defp provider_words(%{"reuse" => "config"}), do: "the config.yaml that was already here"

  defp provider_words(%{"kind" => kind} = provider) do
    name =
      case {kind, provider["provider"]} do
        {"gateway", _} -> "An OpenAI-compatible gateway"
        {"litellm", _} -> "A LiteLLM proxy"
        {_, "anthropic"} -> "Anthropic"
        {_, "openai"} -> "OpenAI"
        {_, "fake"} -> "The fake provider"
        {_, other} -> to_string(other)
      end

    if provider["base_url"], do: "#{name} at #{provider["base_url"]}", else: name
  end

  defp provider_words(_provider), do: ""

  defp describe_offer(offer) do
    context = if offer["context"], do: "#{tokens(offer["context"])} tokens of context"

    price =
      case {offer["input"], offer["output"]} do
        {nil, nil} -> nil
        {input, nil} -> "#{dollars(input)} per million tokens in"
        {nil, output} -> "#{dollars(output)} per million tokens out"
        {input, output} -> "#{dollars(input)} in, #{dollars(output)} out per million tokens"
      end

    case Enum.reject([context, price], &is_nil/1) do
      [] -> "The provider said nothing about its size or price."
      parts -> Enum.join(parts, " · ")
    end
  end

  defp tokens(n) when n >= 1_000_000 and rem(n, 1_000_000) == 0, do: "#{div(n, 1_000_000)}M"
  defp tokens(n) when n >= 1_000, do: "#{div(n, 1_000)}k"
  defp tokens(n), do: to_string(n)

  defp dollars(amount), do: "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)

  defp title(%{step: "where"}), do: "Where does the work run?"
  defp title(%{step: "provider"}), do: "Which model provider?"
  defp title(%{step: "key"}), do: "The key"
  defp title(%{step: "models", part: :main}), do: "Which models? The main one"
  defp title(%{step: "models", part: :small}), do: "Which models? The small one"
  defp title(%{step: "workspace"}), do: "Where is the first project?"

  defp title(%{step: "daemon"} = state),
    do:
      if(at_login_now?(state),
        do: "Troupe starts when you log in",
        else: "Start Troupe when you log in?"
      )

  defp title(%{step: "finish"} = state), do: if(plane?(state), do: "Sign in next", else: "Ready")

  defp lede(%{step: "where"}),
    do:
      "A session is one piece of work handed to the troupe. It can run here, with a model you hold the key to, or on your organisation's Troupe."

  defp lede(%{step: "provider"}),
    do:
      "The provider is who answers the agent. A gateway is a provider too: anything that speaks the OpenAI chat API at an address of yours."

  defp lede(%{step: "key"} = state) do
    storage = get_in(state.flow, ["key_storage", "path"]) || "config.yaml"

    "It is tried once, with a real request to #{provider_name(provider(state))}, before anything is kept. It goes into #{storage} on this computer, readable by you alone (there is no keychain in this build), and it is never shown back."
  end

  defp lede(%{step: "models", part: :main}),
    do:
      "The main model does the editing, usually the capable, expensive one. Prices are per million tokens, in and out, where the provider says."

  defp lede(%{step: "models", part: :small}),
    do:
      "The small model explores, summarises and answers quick questions. The same as the main model is fine."

  defp lede(%{step: "workspace"}),
    do:
      "A session works in one directory: it reads there, edits there, runs commands there, and nothing Troupe keeps for itself lands in it. Then, what the agent may do there without asking."

  defp lede(%{step: "daemon"} = state) do
    if at_login_now?(state) do
      "The daemon on this computer runs your sessions, and it starts when you log in already, so this is not asked: it stays up until you log out."
    else
      path = get_in(state.flow, ["daemon", "path"])
      where = if path, do: " Its entry would be #{path}.", else: ""

      "The daemon on this computer runs your sessions. An app starts it when it needs it, and it stops by itself a while after the last one closes. Started when you log in, it is already there when you open one, and stays up until you log out." <>
        where
    end
  end

  defp lede(%{step: "finish"} = state) do
    if plane?(state),
      do:
        "Nothing is written on this computer for a plane: your organisation's Troupe provides the models and runs the sessions. Enter records the choice, then signs you in (troupe login) and takes its settings (troupe config pull).",
      else:
        "Nothing is written yet. Enter writes what is below and starts the first session in the project, with the question you give it; Esc leaves with nothing written."
  end

  defp at_login_now?(state), do: get_in(state.flow, ["daemon", "at_login"]) == true

  # The summary: what was chosen, and what Enter will write.
  defp facts(state) do
    if plane?(state) do
      [{"Plane", get_in(state.flow, ["answers", "where", "plane_url"]) || ""}]
    else
      local_facts(state)
    end
  end

  defp local_facts(state) do
    provider = provider(state)
    models = state.held["models"]
    key = get_in(state.flow, ["answers", "key"])
    workspace = state.held["workspace"] || %{}
    at_login = get_in(state.held, ["daemon", "at_login"])
    storage = get_in(state.flow, ["key_storage", "path"]) || "config.yaml"
    config = get_in(state.flow, ["detected", "config", "path"]) || storage

    key_line =
      case key do
        %{"source" => "env", "var" => var} -> [{"Key", "read from #{var}"}]
        %{"source" => "typed"} -> [{"Key", "saved in #{storage}"}]
        %{"source" => "none"} -> [{"Key", "none; it wants none"}]
        _ -> []
      end

    model_line =
      if models,
        do: [
          {"Models",
           models["default"] <>
             if(models["cheap"] && models["cheap"] != models["default"],
               do: " · #{models["cheap"]} for small work",
               else: ""
             )}
        ],
        else: []

    approvals =
      if workspace["approvals"] == "auto",
        do: "every call runs without asking",
        else: "the agent asks before it writes or runs anything"

    daemon = if at_login, do: "starts when you log in", else: "starts when an app needs it"

    [{"Provider", provider_words(provider)}] ++
      key_line ++
      model_line ++
      [
        {"Project", workspace["workspace"] || ""},
        {"Approvals", approvals},
        {"Daemon", daemon},
        {"Writes", writes(state, config, at_login)}
      ]
  end

  defp writes(state, config, at_login) do
    status = state.flow["daemon"] || %{}

    settings =
      case provider(state) do
        %{"reuse" => "config"} -> []
        %{"reuse" => "opencode"} -> ["opencode's providers into #{config}"]
        _ -> ["the provider, the key and the models into #{config}"]
      end

    settings =
      if get_in(state.held, ["workspace", "approvals"]) == "auto",
        do: settings ++ ["auto_approve: true into #{config}"],
        else: settings

    login =
      cond do
        at_login and status["at_login"] -> ["the login entry #{status["path"]} again, as it is"]
        at_login -> ["the login entry #{status["path"]}"]
        true -> []
      end

    Enum.join(settings ++ login ++ ["the record that the first run is done"], "; ")
  end

  defp action(%{step: "key"}), do: "checks the key"
  defp action(%{step: "models", part: :main}), do: "picks the main model"
  defp action(%{step: "models", part: :small}), do: "picks the small model"

  defp action(%{step: "finish"} = state),
    do: if(plane?(state), do: "records it and signs in", else: "writes it and starts the session")

  defp action(_state), do: "continues"

  ## Drawing

  defp draw(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [body, footer] = Layout.split(area, :vertical, [{:fill, 1}, {:length, 1}])
    inner = inset(body)
    width = max(inner.width - 4, 10)

    head = head_lines(state, width)
    field = field(state)
    error = if state.error, do: Model.wrap(state.error, width, :word), else: []

    [head_rect, list_rect, field_rect, error_rect] =
      Layout.split(inner, :vertical, [
        {:length, length(head)},
        {:fill, 1},
        {:length, if(field, do: 3, else: 0)},
        {:length, length(error)}
      ])

    [
      {%Paragraph{
         text: "",
         block: %Block{title: " troupe setup ", borders: [:all], border_type: :double}
       }, body},
      {%Paragraph{text: head}, head_rect},
      body_widget(state, list_rect),
      {%Paragraph{text: footer_text(state), style: Theme.style(:muted)}, footer}
    ] ++
      if(field, do: [{field_widget(state, field), field_rect}], else: []) ++
      if(error != [],
        do: [{%Paragraph{text: Enum.map(error, &line(&1, :error))}, error_rect}],
        else: []
      )
  end

  defp inset(%Rect{} = rect),
    do: %Rect{
      x: rect.x + 2,
      y: rect.y + 1,
      width: max(rect.width - 4, 1),
      height: max(rect.height - 2, 1)
    }

  # The row of steps, what the daemon said last, the question and its sentence or two.
  defp head_lines(state, width) do
    steps =
      state
      |> path()
      |> Enum.map(fn step ->
        cond do
          step == state.step -> Span.new("→ " <> @words[step], style: Theme.style(:accent, [:bold]))
          done?(state, step) -> Span.new("✓ " <> @words[step], style: Theme.style(:ok))
          true -> Span.new("· " <> @words[step], style: Theme.style(:muted))
        end
      end)
      |> Enum.intersperse(Span.new("   "))

    said =
      if state.said,
        do: Enum.map(Model.wrap("✓ " <> state.said, width, :word), &line(&1, :ok)),
        else: []

    [Line.new(steps)] ++
      said ++
      [blank(), Line.new([Span.new(title(state), style: Theme.style(nil, [:bold]))])] ++
      Enum.map(Model.wrap(lede(state), width, :word), &line(&1, nil)) ++ [blank()]
  end

  defp blank, do: Line.new([Span.new("")])

  defp done?(state, step) do
    index = Enum.find_index(@steps, &(&1 == step))
    current = Enum.find_index(@steps, &(&1 == state.step))

    index < current and
      (Map.has_key?(state.held, step) or Map.has_key?(state.flow["answers"], step))
  end

  defp body_widget(%{step: "finish"} = state, rect) do
    label_w = 11
    width = max(rect.width - label_w, 10)

    lines =
      Enum.flat_map(facts(state), fn {label, value} ->
        [first | rest] = Model.wrap(value, width, :word) |> then(&if(&1 == [], do: [""], else: &1))

        [
          Line.new([
            Span.new(String.pad_trailing(label, label_w), style: Theme.style(:muted)),
            Span.new(first)
          ])
          | Enum.map(rest, &Line.new([Span.new(String.duplicate(" ", label_w) <> &1)]))
        ]
      end)

    {%Paragraph{text: lines}, rect}
  end

  # Each choice its label, and under it its consequence, wrapped; one the person cannot
  # pick is muted, with why.
  defp body_widget(state, rect) do
    width = max(rect.width - 6, 10)

    items =
      Enum.map(choices(state), fn choice ->
        style = if choice[:off], do: Theme.style(:muted), else: Theme.style(nil, [:bold])
        note = choice[:off] || choice[:note]
        notes = if note, do: Model.wrap(note, width, :word), else: []

        [
          Line.new([Span.new(choice.label, style: style)])
          | Enum.map(notes, &line("  " <> &1, :muted))
        ]
      end)

    list = %ExRatatui.Widgets.List{
      items: items,
      selected: if(items == [], do: nil, else: min(state.cursor, length(items) - 1)),
      highlight_symbol: "▸ ",
      highlight_style: Theme.style(:accent, [:bold])
    }

    {list, rect}
  end

  # What is typed, with the cursor; a key as one dot a character, never itself.
  defp field_widget(state, field) do
    {text, pos} = state.input
    shown = if field.secret?, do: String.duplicate("•", String.length(text)), else: text
    {before, after_} = String.split_at(shown, pos)

    %Paragraph{
      text: before <> Input.cursor_glyph() <> after_,
      block: %Block{title: " " <> field.label <> " ", borders: [:all]}
    }
  end

  defp footer_text(%{busy: busy}) when busy != nil, do: " " <> busy

  defp footer_text(state) do
    leave =
      if state.wrote, do: "Esc leaves; what is saved stays", else: "Esc leaves, nothing written"

    back = if back?(state), do: " · Shift-Tab back", else: ""
    choose = if choices(state) == [], do: "", else: " · ↑↓ choose"
    " Enter #{action(state)}#{choose}#{back} · #{leave}"
  end

  defp back?(%{step: "models", part: :small}), do: true
  defp back?(state), do: Enum.find_index(path(state), &(&1 == state.step)) not in [nil, 0]

  defp line(text, role), do: Line.new([Span.new(text, style: Theme.style(role))])
end
