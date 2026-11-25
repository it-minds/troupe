defmodule Troupe.Session.Proposals.TriggerRule do
  @moduledoc """
  When to offer a trigger that reruns what a session published (#1208), by rule and with no
  model call: a fold of the session's log, and at the root's rest the draft or `nil`.

  It proposes where, in the turn that just ended, a `publish_artifact` completed with an
  artifact, and earlier in the session at least one call read live data: `web_fetch`, an MCP
  server's tool, or a shell command from a short list (`curl`, `psql`, `gh`, `kubectl get`
  and the like, `live_commands/0`). Never in a session something other than a person
  started (an `origin` that is not a user's, or a `trigger_fired`), which already recurs.

  The draft is what a yes makes, as the owner may edit it:

    * the schedule from the person's own words in the turn ("every Monday", "daily",
      "weekdays", "monthly"), else every Monday at 06:00 UTC, in five-field cron;
    * the prompt: the person's instruction that led to the publish, the sources read said
      in words, and the line that publishes the result as the next version of the same
      artifact, with its audience, so the run's publish needs nobody to choose one;
    * the session's profile, agent and visibility; `review: required`; the owner told of
      each run; a modest budget; `approvals: deny`, with the tools the session used allowed
      (`terms.allow`, per-tool rules), `publish_artifact` first, so a run does not stop at
      the publish it exists for.

  Pure: `fold/2` takes durable events oldest first, `draft/1` answers at a rest, `rested/1`
  starts the next turn.
  """

  alias Troupe.Config.Permissions
  alias Troupe.Protocol.{Event, Text}

  # Commands whose output is somebody else's live data, as the line starts.
  @live_commands ["curl", "wget", "psql", "sqlite3", "mysql", "gh", "kubectl get", "az", "aws", "bq"]

  @default_cron "0 6 * * 1"
  @budget_micros 1_000_000
  @max_instruction_bytes 4_000
  @max_sources 8

  @days %{
    "sunday" => 0,
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6
  }

  defstruct origin: nil,
            triggered: false,
            profile: nil,
            agent: nil,
            visibility: nil,
            owner: nil,
            started: %{},
            reads: [],
            # This turn's: what the person said, and the publish it ended with.
            words: [],
            publish: nil

  @type t :: %__MODULE__{}

  @doc "The shell commands that count as a read of live data, as a command line starts."
  @spec live_commands() :: [String.t()]
  def live_commands, do: @live_commands

  @doc "The budget of one run a draft proposes, in micros."
  @spec budget_micros() :: pos_integer()
  def budget_micros, do: @budget_micros

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Fold one durable event."
  @spec fold(t(), Event.t()) :: t()
  def fold(%__MODULE__{} = s, %Event{ephemeral?: true}), do: s

  def fold(s, %Event{type: "session_created", data: data}) do
    %{
      s
      | origin: data["origin"],
        profile: data["profile"],
        visibility: data["visibility"],
        owner: data["owner"]
    }
  end

  def fold(s, %Event{type: "trigger_fired"}), do: %{s | triggered: true}
  def fold(s, %Event{type: "session_visibility_changed", data: data}), do: %{s | visibility: data["visibility"]}

  def fold(s, %Event{type: "agent_started", agent: ["root"], data: data}),
    do: %{s | agent: data["profile"] || s.agent}

  def fold(s, %Event{type: "profile_switched", agent: ["root"], data: data}),
    do: %{s | agent: data["to"] || s.agent}

  def fold(s, %Event{type: "user_input", agent: ["root"], data: %{"text" => text} = data})
      when is_binary(text) do
    if data["child_path"], do: s, else: %{s | words: s.words ++ [text]}
  end

  def fold(s, %Event{type: "tool_call_started", data: %{"call_id" => id, "name" => name} = data}),
    do: %{s | started: Map.put(s.started, id, %{name: name, args: data["args"] || %{}})}

  # The audience the person chose at the approval is the one the call ran with.
  def fold(s, %Event{type: "approval_decided", data: %{"call_id" => id, "tool" => "publish_artifact"} = data}) do
    case {s.started[id], data["visibility"]} do
      {%{args: args} = call, visibility} when is_binary(visibility) ->
        %{s | started: Map.put(s.started, id, %{call | args: Map.put(args, "visibility", visibility)})}

      _ ->
        s
    end
  end

  def fold(s, %Event{type: "tool_call_completed", data: %{"call_id" => id, "ok" => true} = data}) do
    {call, started} = Map.pop(s.started, id)
    s = %{s | started: started}

    case call do
      %{name: "publish_artifact", args: args} ->
        case data["artifact"] do
          %{"id" => artifact_id} = artifact when is_binary(artifact_id) ->
            %{s | publish: %{artifact: artifact, args: args}}

          _none ->
            s
        end

      %{name: name, args: args} ->
        case read(name, args) do
          nil -> s
          read -> %{s | reads: Enum.uniq(s.reads ++ [read])}
        end

      nil ->
        s
    end
  end

  def fold(s, %Event{type: "tool_call_completed", data: %{"call_id" => id}}),
    do: %{s | started: Map.delete(s.started, id)}

  def fold(s, %Event{}), do: s

  @doc "The turn is over: what it said and published is no longer this turn's."
  @spec rested(t()) :: t()
  def rested(%__MODULE__{} = s), do: %{s | words: [], publish: nil}

  @doc """
  The proposal the turn that just ended earns, without its `id`: `kind`, `key`, `title`,
  `why`, `draft`; or `nil`.
  """
  @spec draft(t()) :: map() | nil
  def draft(%__MODULE__{publish: nil}), do: nil
  def draft(%__MODULE__{reads: []}), do: nil
  def draft(%__MODULE__{triggered: true}), do: nil

  def draft(%__MODULE__{} = s) do
    if started_by_a_person?(s.origin), do: propose(s), else: nil
  end

  defp started_by_a_person?(nil), do: true
  defp started_by_a_person?(%{"kind" => "user"}), do: true
  defp started_by_a_person?(_other), do: false

  defp propose(%__MODULE__{publish: %{artifact: artifact, args: args}} = s) do
    {cron, schedule} = schedule(Enum.join(s.words, "\n"))
    title = args["title"] || artifact["title"] || artifact["id"]
    visibility = args["visibility"]

    %{
      "kind" => "trigger",
      "key" => "artifact:" <> artifact["id"],
      "title" => "Rerun this report #{schedule}?",
      "why" => why(s.reads),
      "draft" => %{
        "name" => name(title),
        "schedule" => schedule,
        "source" => %{"kind" => "schedule", "cron" => cron, "tz" => "UTC"},
        "prompt_template" => prompt(s, artifact, title, visibility),
        "profile" => s.profile,
        "agent" => s.agent,
        "visibility" => if(s.visibility == "team", do: "team", else: "private"),
        "review" => "required",
        "notify" => Enum.reject([s.owner], &is_nil/1),
        "terms" => %{
          "budget_micros" => @budget_micros,
          "approvals" => "deny",
          "allow" => allow(s.reads)
        },
        "artifact" =>
          %{"id" => artifact["id"], "title" => title, "version" => artifact["version"], "url" => artifact["url"]}
          |> Map.merge(if(artifact["owner_team"], do: %{"owner_team" => artifact["owner_team"]}, else: %{}))
          |> Map.merge(if(is_binary(visibility), do: %{"visibility" => visibility}, else: %{}))
      }
    }
  end

  # -- what counts as live --------------------------------------------------------

  defp read("web_fetch", %{"url" => url}) when is_binary(url), do: %{"tool" => "web_fetch", "source" => url}
  defp read("web_fetch", _args), do: %{"tool" => "web_fetch", "source" => nil}

  defp read("mcp." <> name, _args), do: %{"tool" => "mcp", "source" => name}

  defp read("shell", %{"command" => command}) when is_binary(command) do
    {commands, _complex?} = Permissions.commands(command)

    Enum.find_value(commands, fn line ->
      case Enum.find(@live_commands, &(line == &1 or String.starts_with?(line, &1 <> " "))) do
        nil -> nil
        live -> %{"tool" => "shell", "source" => line, "command" => live}
      end
    end)
  end

  defp read(_name, _args), do: nil

  # The rules a run needs to do the same unasked: the publish, then each kind of read.
  defp allow(reads) do
    rules =
      Enum.map(reads, fn
        %{"tool" => "web_fetch"} -> "web_fetch"
        %{"tool" => "mcp", "source" => name} -> "mcp(#{name})"
        %{"tool" => "shell", "command" => live} -> "shell(#{live})"
      end)

    Enum.uniq(["publish_artifact" | rules])
  end

  defp why(reads) do
    counts =
      reads
      |> Enum.group_by(& &1["tool"])
      |> Enum.sort_by(fn {tool, _} -> Enum.find_index(~w(web_fetch mcp shell), &(&1 == tool)) end)
      |> Enum.map(fn
        {"web_fetch", list} -> Troupe.Protocol.Words.count(length(list), "page fetched", "pages fetched")
        {"mcp", list} -> Troupe.Protocol.Words.count(length(list), "MCP tool", "MCP tools")
        {"shell", list} -> Troupe.Protocol.Words.count(length(list), "query from the shell", "queries from the shell")
      end)

    "It was built from live data (#{Troupe.Protocol.Words.and_list(counts)}), which a rerun reads again."
  end

  # -- the schedule ---------------------------------------------------------------

  @doc """
  The schedule a person's words ask for: `{cron, words}`, the cron in five fields at 06:00
  UTC, the words as a question ends ("every week"). Weekly on Monday where they say none.
  """
  @spec schedule(String.t()) :: {String.t(), String.t()}
  def schedule(text) when is_binary(text) do
    said = String.downcase(text)

    cond do
      said =~ ~r/\b(every|each) ?(week ?day|weekday)s?\b|\bweekdays\b|\bon weekdays\b/ ->
        {"0 6 * * 1-5", "every weekday"}

      day = said_day(said) ->
        {"0 6 * * #{@days[day]}", "every #{String.capitalize(day)}"}

      said =~ ~r/\b(daily|every day|each day|every morning|each morning|every night|nightly)\b/ ->
        {"0 6 * * *", "every day"}

      said =~ ~r/\b(monthly|every month|each month)\b/ ->
        {"0 6 1 * *", "every month"}

      true ->
        {@default_cron, "every week"}
    end
  end

  defp said_day(said) do
    Enum.find(Map.keys(@days), fn day ->
      said =~ ~r/\b(every|each|on) #{day}s?\b|\b#{day}s\b/
    end)
  end

  # -- the prompt -----------------------------------------------------------------

  defp prompt(s, artifact, title, visibility) do
    instruction =
      case Enum.reject(s.words, &(String.trim(&1) == "")) do
        [first | _] -> Text.cut(String.trim(first), @max_instruction_bytes)
        [] -> "Make the report \"#{title}\" again."
      end

    audience = if is_binary(visibility), do: ", `visibility` `#{visibility}`", else: ""

    Enum.join(
      [
        instruction,
        sources(s.reads),
        "Publish the result with publish_artifact as the next version of \"#{title}\": `id` " <>
          "`#{artifact["id"]}`#{audience}, and a `note` naming the date of this run."
      ]
      |> Enum.reject(&(&1 == "")),
      "\n\n"
    )
  end

  defp sources(reads) do
    reads = Enum.take(reads, @max_sources)

    parts =
      [
        reads |> Enum.filter(&(&1["tool"] == "web_fetch" and &1["source"])) |> Enum.map(& &1["source"]),
        reads |> Enum.filter(&(&1["tool"] == "mcp")) |> Enum.map(&"the MCP tool #{&1["source"]}"),
        reads |> Enum.filter(&(&1["tool"] == "shell")) |> Enum.map(&"`#{Text.cut(&1["source"], 200)}`")
      ]
      |> List.flatten()

    if parts == [], do: "", else: "Read the same sources again: " <> Enum.join(parts, ", ") <> "."
  end

  defp name(title) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    if slug == "", do: "rerun-report", else: "rerun-" <> slug
  end
end
