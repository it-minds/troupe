defmodule Troupe.Client.Daemon.Start do
  @moduledoc """
  What a new session on this machine asks at its start (root Decision 835, TUI Decision
  154): onboarding first, then the brief.

  The daemon says what is due (`onboard.plan`); the questions are this client's, asked in
  the session's root window as `:local_question` events of its own (`Worker.post/3`, so
  each lands after the session's first event) and answered with one key
  (`Troupe.Client.answer_local/3`), each answer an event too, so a screen rebuilt from the
  journal draws what is still asked and nothing that was answered.

  - **Onboarding, when it is due.** `first`: "Onboard 5 files from Claude Code and Cursor
    into Troupe's own? [Y/n/r]", the files listed under it. `y` writes every ordinary file
    (`onboard.apply` with `all`), then asks for each new `AGENTS.md` on its own (root
    Decision 827), No the default; `r` shows each file as `troupe onboard` shows it and
    asks for it, No the default; `n` says no to all of them, remembered for this version
    of the rules. `outdated`: "Onboarding rules changed since this repository was
    onboarded (v1 to v2). Re-run now? [Y/n]", which writes and asks as `y` does.
  - **Then the brief.** Only once onboarding is answered, so the librarian reads the
    `AGENTS.md` it wrote. A brief an older survey wrote is asked about: "The librarian's
    survey changed (v1 to v2): rewrite the brief now? [Y/n]"; `n` is remembered for that
    version (`memory.decline`). Otherwise the librarian starts as it did (TUI Decisions
    127 and 131): on a missing or stale brief, when `memory_auto_refresh` asks and the
    daemon says it is due, saying why when it starts none for a reason a person would want.

  Only in a git repository, which is what both describe: `troupe` opened in a home
  directory asks nothing. A headless run asks nothing (it passes `refresh_brief: false`);
  the daemon's `onboarding_suggested` is its line. A daemon from before `onboard.plan`
  starts the librarian as before.
  """

  alias Troupe.CLI.Onboard, as: Shown
  alias Troupe.Client.Daemon
  alias Troupe.Client.Daemon.Link
  alias Troupe.Config
  alias Troupe.Remote.{Journal, Worker}

  require Logger

  @refresh_prompt "The project brief is out of date. Revise it against the repository as it is now."
  @first_prompt "There is no project brief yet. Survey this repository and write one."

  @doc "What `/memory refresh` asks the librarian."
  @spec refresh_prompt() :: String.t()
  def refresh_prompt, do: @refresh_prompt

  @doc """
  A new session's start: the onboarding question when it is due, and otherwise the
  brief's step at once.
  """
  @spec begin(String.t(), String.t()) :: :ok
  def begin(sid, workspace) do
    if repository?(workspace) do
      case Link.call("onboard.plan", %{workspace: workspace}) do
        {:ok, %{"onboarding" => %{} = onboarding} = plan} ->
          onboarding(sid, workspace, onboarding, plan["refusal"], brief_of(plan["brief"]))

        {:ok, other} ->
          Logger.warning(
            "no onboarding question: unexpected onboard.plan answer: #{inspect(other)}"
          )

          brief(sid, workspace, nil)

        {:error, reason} ->
          Logger.info("no onboarding question for #{workspace}: #{message(reason)}")
          brief(sid, workspace, nil)
      end
    else
      brief(sid, workspace, nil)
    end

    :ok
  end

  @doc """
  An answer to a question `begin/2` asked, or one that followed it: one of its `keys`, or
  `""` for its default.
  """
  @spec answer(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def answer(sid, id, key) do
    case asked(sid, id) do
      nil ->
        {:error, "that question was answered already"}

      question ->
        key = if key == "", do: question.default, else: String.downcase(key)

        if key in question.keys,
          do: take(sid, id, question, key),
          else: {:error, "answer with " <> Enum.join(question.keys, ", ")}
    end
  end

  # A session let go of meanwhile takes no answer, and the question stays for its next
  # screen.
  defp take(sid, id, question, key) do
    case Worker.post(sid, :local_question_answered, %{id: id, answer: key}) do
      :ok ->
        go_on(sid, question, key)
        :ok

      {:error, reason} ->
        {:error, "the answer was not taken: #{message(reason)}"}
    end
  end

  ## Onboarding

  defp onboarding(sid, workspace, %{"due" => due} = onboarding, nil, brief)
       when due in ["first", "outdated"] do
    items = Enum.map(onboarding["items"] || [], &Shown.entry/1)
    skipped = onboarding["skipped"] || []

    ask(sid, %{
      step: due,
      question: onboarding_question(due, onboarding, items),
      keys: if(due == "first", do: ["y", "n", "r"], else: ["y", "n"]),
      default: "y",
      preview: listing(items, skipped),
      workspace: workspace,
      brief: brief,
      items: items
    })
  end

  defp onboarding(sid, workspace, _onboarding, _refusal, brief), do: brief(sid, workspace, brief)

  defp onboarding_question("first", onboarding, items) do
    "Onboard #{count(length(items), "file")} from #{tools(onboarding["tools"])} into " <>
      "Troupe's own?"
  end

  defp onboarding_question("outdated", onboarding, _items) do
    "Onboarding rules changed since this repository was onboarded " <>
      "(v#{onboarding["recorded"]} to v#{onboarding["version"]}). Re-run now?"
  end

  defp tools([_ | _] = names) do
    case Enum.split(names, -1) do
      {[], [only]} -> only
      {rest, [last]} -> Enum.join(rest, ", ") <> " and " <> last
    end
  end

  defp tools(_none), do: "other tools"

  # The files the question is about, one a line, and what was found and not proposed.
  defp listing(items, skipped) do
    files =
      Enum.map(items, fn item ->
        word = if item.change == "new", do: "new", else: "changed"
        "#{item.shown} (#{word}, from #{item.from})"
      end)

    skips = Enum.map(skipped, &"skipped: #{&1["source"]}: #{&1["reason"]}")

    case files ++ skips do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp go_on(sid, %{step: step} = q, "y") when step in ["first", "outdated"] do
    case Link.call("onboard.apply", %{workspace: q.workspace, all: true, command_id: command_id()}) do
      {:ok, answer} -> said(sid, q.items, answer)
      {:error, reason} -> note(sid, "nothing onboarded: #{message(reason)}")
    end

    creates(sid, q, Enum.filter(q.items, &(&1.ask == "create_agents_md")))
  end

  defp go_on(sid, %{step: step} = q, "n") when step in ["first", "outdated"] do
    case Link.call("onboard.decline", %{workspace: q.workspace, all: true, command_id: command_id()}) do
      {:ok, %{"declined" => n}} ->
        note(
          sid,
          "left out #{count(n, "file")}; not asked again at a start, and " <>
            "`troupe onboard --all` offers #{if n == 1, do: "it", else: "them"} again"
        )

      {:error, reason} ->
        note(sid, "the no was not remembered: #{message(reason)}")
    end

    brief(sid, q.workspace, q.brief)
  end

  defp go_on(sid, %{step: "first"} = q, "r"), do: review(sid, q, q.items)

  defp go_on(sid, %{step: "review"} = q, key) do
    one(sid, q, key)
    review(sid, q, q.rest)
  end

  defp go_on(sid, %{step: "agents_md"} = q, key) do
    one(sid, q, key)
    creates(sid, q, q.rest)
  end

  defp go_on(sid, %{step: "brief"}, "y") do
    case Daemon.dispatch(sid, "librarian", @refresh_prompt) do
      {:ok, _window} ->
        :ok

      {:error, reason} ->
        note(
          sid,
          "no librarian for the project brief: the daemon did not start it: #{message(reason)}"
        )
    end
  end

  defp go_on(sid, %{step: "brief"} = q, "n") do
    case Link.call("memory.decline", %{workspace: q.workspace, command_id: command_id()}) do
      {:ok, _} ->
        note(
          sid,
          "the brief stays as it is until the survey changes again; /memory refresh rewrites it"
        )

      {:error, reason} ->
        note(sid, "the no was not remembered: #{message(reason)}")
    end
  end

  # Each file on its own, as `troupe onboard` shows and asks it.
  defp review(sid, q, [item | rest]), do: ask(sid, per_file(q, "review", item, rest))
  defp review(sid, q, []), do: brief(sid, q.workspace, q.brief)

  # Each new `AGENTS.md`, asked on its own after a yes to the rest (root Decision 827).
  defp creates(sid, q, [item | rest]), do: ask(sid, per_file(q, "agents_md", item, rest))
  defp creates(sid, q, []), do: brief(sid, q.workspace, q.brief)

  defp per_file(q, step, item, rest) do
    %{
      step: step,
      question: Shown.question(item),
      keys: ["y", "n"],
      default: "n",
      preview: Shown.describe(item),
      workspace: q.workspace,
      brief: q.brief,
      item: item,
      rest: rest
    }
  end

  defp one(sid, q, "y") do
    case Link.call("onboard.apply", %{
           workspace: q.workspace,
           ids: [q.item.id],
           command_id: command_id()
         }) do
      {:ok, answer} -> said(sid, [q.item], answer)
      {:error, reason} -> note(sid, "not onboarded: #{q.item.shown}: #{message(reason)}")
    end
  end

  defp one(sid, q, "n") do
    case Link.call("onboard.decline", %{
           workspace: q.workspace,
           ids: [q.item.id],
           command_id: command_id()
         }) do
      {:ok, _} ->
        note(sid, "left out #{q.item.shown}; not asked about again until #{q.item.from} changes")

      {:error, reason} ->
        note(sid, "left out #{q.item.shown} (not remembered: #{message(reason)})")
    end
  end

  # What a write did, a line a file.
  defp said(sid, items, answer) do
    shown = Map.new(items, &{&1.id, &1.shown})

    for written <- answer["written"] || [], do: note(sid, "onboarded #{written["shown"]}")

    for refused <- answer["refused"] || [],
        do:
          note(sid, "not onboarded: #{shown[refused["id"]] || refused["id"]}: #{refused["reason"]}")

    :ok
  end

  ## The brief

  # The librarian's step, once onboarding is answered. A new session on a repository with
  # no brief, or a stale one, starts the librarian as a branch when the workspace config
  # asks for it (`memory_auto_refresh`, the default); one an older survey wrote is asked
  # about first. Off in tests and for anyone who would rather run `/memory refresh`. Only
  # in a git repository, which is what a brief describes — `troupe` opened in a home
  # directory surveys nothing — and only with a model to ask, or the first thing a new
  # user saw would be the librarian failing beside their own first turn.
  #
  # When none starts, the log says why, and so does a line in the session's window when
  # it is something a person can act on or would otherwise wonder about: no model to ask,
  # a daemon that did not answer or refused the branch, a try that is being waited out
  # (TUI Decision 131). Memory turned off, a directory git does not know and a fresh brief
  # are the ordinary cases and say nothing on screen.
  defp brief(sid, workspace, brief) do
    case brief_step(sid, workspace, brief) do
      result when result in [:started, :asked] ->
        :ok

      {:quiet, why} ->
        Logger.info("no librarian for #{workspace}: #{why}")

      {:say, why} ->
        Logger.warning("no librarian for #{workspace}: #{why}")
        _ = Worker.note(sid, "no librarian for the project brief: " <> why)
        :ok
    end
  end

  defp brief_step(sid, workspace, brief) do
    config = config(workspace)

    cond do
      config.memory == false -> {:quiet, "memory is off"}
      config.memory_auto_refresh == false -> {:quiet, "memory_auto_refresh is off"}
      not repository?(workspace) -> {:quiet, "not a git repository"}
      problem = Config.key_problem(config) -> {:say, no_model(problem)}
      match?(%{due: "outdated"}, brief) -> ask_brief(sid, workspace, brief)
      true -> refresh_if_due(sid, workspace)
    end
  end

  defp ask_brief(sid, workspace, brief) do
    ask(sid, %{
      step: "brief",
      question:
        "The librarian's survey changed (v#{brief.recorded} to v#{brief.version}): " <>
          "rewrite the brief now?",
      keys: ["y", "n"],
      default: "y",
      preview: nil,
      workspace: workspace,
      brief: brief
    })

    :asked
  end

  # A new session on a repository with no brief, or a stale one, starts the librarian as a
  # branch when the daemon says the refresh is due: a librarian that tried lately and built
  # nothing is not tried again in every session (TUI Decision 127); a daemon too old to say
  # leaves it to the status.
  defp refresh_if_due(sid, workspace) do
    case Link.call("memory.get", %{workspace: workspace}) do
      {:ok, %{"refresh_due" => false, "status" => status} = brief}
      when status in ["absent", "stale"] ->
        {:say, held_off(brief["refresh_held_until"])}

      {:ok, %{"refresh_due" => false, "status" => status}} ->
        {:quiet, "the brief is #{status}"}

      {:ok, %{"status" => status}} when status in ["absent", "stale"] ->
        prompt = if status == "absent", do: @first_prompt, else: @refresh_prompt

        case Daemon.dispatch(sid, "librarian", prompt) do
          {:ok, _window} -> :started
          {:error, reason} -> {:say, "the daemon did not start it: #{message(reason)}"}
        end

      {:ok, %{"status" => status}} ->
        {:quiet, "the brief is #{status}"}

      {:ok, other} ->
        {:say, "unexpected memory.get answer: #{inspect(other)}"}

      {:error, reason} ->
        {:say, "the daemon did not say whether one is due: #{message(reason)}"}
    end
  end

  defp no_model({:no_key, name}),
    do: "#{name} has no key, so no model can be asked; `troupe config` sets one up"

  defp no_model({:refused, why}), do: why

  # A daemon from before the date leaves it out.
  defp held_off(until) when is_binary(until) do
    "the last one built none, so the next waits until #{String.slice(until, 0, 10)}; " <>
      "/memory refresh starts one now"
  end

  defp held_off(_until),
    do: "the last one built none, so the next waits a while; /memory refresh starts one now"

  ## Questions

  defp ask(sid, question) do
    id = "start-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    case Worker.post(sid, :local_question, Map.put(question, :id, id)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("no question at #{sid}'s start: #{message(reason)}")
    end
  end

  # The question `id` names, as it was asked, while nobody has answered it.
  defp asked(sid, id) do
    events = Journal.all(sid)

    if Enum.any?(events, &(&1.type == :local_question_answered and &1.data.id == id)),
      do: nil,
      else: Enum.find_value(events, &(&1.type == :local_question and &1.data.id == id and &1.data))
  end

  defp note(sid, text), do: Worker.note(sid, text)

  defp brief_of(%{"due" => due} = brief),
    do: %{due: due, recorded: brief["recorded"] || 0, version: brief["version"]}

  defp brief_of(_none), do: nil

  defp config(workspace) do
    case Config.resolve(workspace) do
      {:ok, config, _layers} -> config
      {:error, error} -> %Config{warnings: [Exception.message(error)]}
    end
  end

  # In a git work tree: a `.git` directory, or the `.git` file a worktree has, here or in
  # a directory above.
  defp repository?(dir) do
    dir = Path.expand(dir)

    cond do
      File.exists?(Path.join(dir, ".git")) -> true
      Path.dirname(dir) == dir -> false
      true -> repository?(Path.dirname(dir))
    end
  end

  defp command_id, do: Troupe.Remote.RPC.command_id()

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp message(reason) when is_binary(reason), do: reason
  defp message(%{message: text}) when is_binary(text), do: text
  defp message(reason), do: inspect(reason)
end
