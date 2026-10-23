defmodule Troupe.UI.TUI.AgentChooser do
  @moduledoc """
  The one agent picker (#594): every primary agent the session
  can pick, from the daemon's `agents.list` for the session and nothing else, each row
  saying where it comes from in the four words a person uses (`Shipped`, `Your
  organisation's`, `Yours`, `This repository's`) and what it may do — its model,
  read-only or not, whether a session on it gets a worktree, why it cannot run here when
  it cannot — and beside the list the highlighted agent's description, what it stands in
  for and as much of its instruction as fits, read through `agents.get` as the cursor
  reaches it.

  Three things are done from it, each a key, wherever it was opened:

  - **Start** a branch on the agent (`b`): where it works is the next step, a worktree of
    its own (`w`) or the checkout (`c`), as Ctrl-N offered.
  - **Switch** the window it was opened over to the agent (`s`), keeping its
    conversation (`profile.switch`, root Decision 841); on a pod, the session's own.
  - **Edit** the agent's file (`e`), in the person's editor through `/agents`.

  Enter does what it was opened for: Ctrl-N's is a start, Tab's a switch, `/new`'s a new
  session on the agent, and `/agents`' reads the agent whole. What the session cannot do
  is refused here, with why, before anything is asked of the daemon: an agent whose model
  the provider does not serve, a subagent (an agent hands work to one; nothing starts it),
  a start on a pod (which starts no branches), a switch with no window, and an edit of a
  bundle's agent or of anything on a pod.

  Two densities of the one list. The picker's (Ctrl-N, Tab, `/new`) is the primaries, each
  row its origin and badges. The manager's (`/agents`) lists the subagents too, each row
  saying its mode, model, tools, cap on turns and what it stands in for, and adds the
  manager's own keys, each done by `/agents`' page on the agent and coming back here:
  `c` copies it into a layer, `n` makes a new agent from it (a built-in or the
  organisation's as well as a person's own), `x` deletes it, `v` reads it whole. `n` is
  the picker's too. A save comes back here with the cursor on what was saved, so Enter
  starts on it.

  `open/3` with the session, `key/3` for its keys, `render/3` for its widgets over
  whatever is behind it.
  """

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.TUI.{Agents, Model, Theme}

  @typedoc """
  The rows offered, the cursor, the agent in use now (`current`, marked and where the
  cursor starts), what each was read as whole (`details`), the popup's title, `for`, what
  it was opened for (`{:window, path}` to switch, `{:start, prompt}` to start, `{:new,
  kind}` for a new session, `:manage` for `/agents`), `density` (`:picker` or `:manager`),
  `window`, the window `s` switches (nil where there is none), `start`, why a start is
  refused here (nil where one is not), `read_only`, the listing's own sentence where
  nothing is edited here (a pod's), `step` (the agent, then where a start works, `where` 0
  for a worktree and 1 for the checkout), and `status`, the picker's own line of news.
  """
  @type t :: %{
          rows: [map()],
          cursor: non_neg_integer(),
          current: String.t() | nil,
          details: %{optional(String.t()) => map()},
          title: String.t(),
          for: {:window, String.t()} | {:start, String.t()} | {:new, term()} | :manage | term(),
          density: :picker | :manager,
          window: String.t() | nil,
          start: String.t() | nil,
          read_only: String.t() | nil,
          step: :agent | :where,
          where: 0 | 1,
          status: String.t() | nil
        }

  @doc """
  A picker over the session's agents, the cursor on `current`: its primaries, and at the
  manager's density its subagents too. Options: `title`, `for`, `density`, `window` and
  `start` (as `t:t/0` says). `{:error, reason}` when the daemon lists none.
  """
  @spec open(String.t(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, String.t()}
  def open(sid, current, opts \\ []) do
    density = Keyword.get(opts, :density, :picker)

    case list(sid, density) do
      {:ok, %{"agents" => [_ | _]} = listed} ->
        rows = rows(listed, density)

        chooser = %{
          rows: rows,
          cursor: Enum.find_index(rows, &(&1["name"] == current)) || 0,
          current: current,
          details: %{},
          title: Keyword.get(opts, :title, " choose an agent "),
          for: Keyword.get(opts, :for),
          density: density,
          window: Keyword.get(opts, :window),
          start: Keyword.get(opts, :start),
          read_only: listed["read_only"],
          step: :agent,
          where: 0,
          status: nil
        }

        {:ok, fetch(chooser, sid)}

      {:ok, _none} ->
        {:error, "the daemon lists no agents to choose from"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp list(sid, :manager), do: Client.agents(sid, "agents.list", %{subagents: true})
  defp list(sid, _picker), do: Client.agents(sid, "agents.list")

  # The manager's density lists the files found and not read as well, after the agents,
  # each with why: `e` opens one to mend it, as `/agents` always has.
  defp rows(listed, :manager),
    do: List.wrap(listed["agents"]) ++ Enum.map(List.wrap(listed["skipped"]), &skipped_row/1)

  defp rows(listed, _picker), do: List.wrap(listed["agents"])

  defp skipped_row(skipped) do
    name = skipped["name"] || Path.basename(to_string(skipped["path"]), ".md")
    %{"name" => name, "skipped" => true, "path" => skipped["path"], "reason" => skipped["reason"]}
  end

  @doc """
  The listing read again, after something was saved or taken away: the cursor on `select`
  when it is listed (else where it was), the step back to the agent, and `status` on the
  picker's line, with what Enter now does to the agent selected when one was saved.
  """
  @spec reload(t(), String.t(), String.t() | nil, String.t() | nil) :: t()
  def reload(chooser, sid, select \\ nil, status \\ nil) do
    rows =
      case list(sid, chooser.density) do
        {:ok, %{"agents" => [_ | _]} = listed} -> rows(listed, chooser.density)
        _none -> chooser.rows
      end

    name = select || Map.get(Enum.at(chooser.rows, chooser.cursor) || %{}, "name")

    cursor =
      Enum.find_index(rows, &(&1["name"] == name)) ||
        min(chooser.cursor, max(length(rows) - 1, 0))

    chooser = %{chooser | rows: rows, cursor: cursor, details: %{}, step: :agent, status: nil}
    chooser = fetch(chooser, sid)

    then =
      if is_binary(select) and Enum.at(rows, cursor)["name"] == select,
        do: next_words(chooser, select),
        else: nil

    %{chooser | status: [status, then] |> Enum.reject(&is_nil/1) |> join_status()}
  end

  defp join_status([]), do: nil
  defp join_status(parts), do: Enum.join(parts, " · ")

  # What a key does now to an agent just saved: making it and using it are one step.
  defp next_words(%{for: {:new, _kind}}, name), do: "Enter starts a new session on #{name}"
  defp next_words(%{for: {:start, _prompt}}, name), do: "Enter starts a branch on #{name}"
  defp next_words(%{for: {:window, path}}, name), do: "Enter switches #{path} to #{name}"
  defp next_words(_chooser, name), do: "b starts a branch on #{name}"

  @doc """
  One key: `{:ok, chooser}` stays open, `:close` closes it, and the actions, each for an
  agent the session can run: `{:start, name, :worktree | :checkout}`, `{:switch, name,
  window}`, `{:new, name}` (a new session on it, for `/new`), `{:manage, name, key}`
  (`/agents`' page on the agent, given that key: `e` edits, `c` copies, `x` deletes, `v`
  reads it whole) and `{:new_from, name}` (a new agent made from it). What is refused
  stays open with why on its line.
  """
  @spec key(t(), Key.t(), String.t()) ::
          {:ok, t()}
          | :close
          | {:start, String.t(), :worktree | :checkout}
          | {:switch, String.t(), String.t()}
          | {:new, String.t()}
          | {:manage, String.t(), String.t()}
          | {:new_from, String.t()}
  def key(%{step: :where} = chooser, key, _sid), do: where_key(chooser, key)

  def key(_chooser, %Key{code: "esc"}, _sid), do: :close

  def key(chooser, %Key{code: code}, sid) when code in ["up", "k", "backtab"],
    do: {:ok, move(chooser, -1, sid)}

  def key(chooser, %Key{code: code}, sid) when code in ["down", "j", "tab"],
    do: {:ok, move(chooser, 1, sid)}

  def key(chooser, %Key{code: "home"}, sid), do: {:ok, move(chooser, -1_000, sid)}
  def key(chooser, %Key{code: "end"}, sid), do: {:ok, move(chooser, 1_000, sid)}

  def key(%{for: {:window, _path}} = chooser, %Key{code: "enter"}, _sid), do: switch(chooser)
  def key(%{for: {:new, _kind}} = chooser, %Key{code: "enter"}, _sid), do: new_session(chooser)
  def key(%{for: :manage} = chooser, %Key{code: "enter"}, _sid), do: manage(chooser, "v")
  def key(chooser, %Key{code: "enter"}, _sid), do: start(chooser)
  def key(chooser, %Key{code: "s"}, _sid), do: switch(chooser)
  def key(%{for: {:new, _kind}} = chooser, %Key{code: "b"}, _sid), do: new_session(chooser)
  def key(chooser, %Key{code: "b"}, _sid), do: start(chooser)
  def key(chooser, %Key{code: "e"}, _sid), do: edit(chooser)
  def key(chooser, %Key{code: "n"}, _sid), do: new_from(chooser)
  def key(chooser, %Key{code: "r"}, sid), do: {:ok, reload(chooser, sid, nil, "read again")}

  def key(%{density: :manager} = chooser, %Key{code: code}, _sid) when code in ["c", "x", "v"],
    do: manage(chooser, code)

  def key(chooser, _key, _sid), do: {:ok, chooser}

  defp where_key(chooser, %Key{code: "esc"}), do: {:ok, %{chooser | step: :agent}}

  defp where_key(chooser, %Key{code: code}) when code in ["up", "k", "down", "j"],
    do: {:ok, %{chooser | where: if(code in ["up", "k"], do: 0, else: 1)}}

  defp where_key(chooser, %Key{code: "w"}), do: {:start, name(chooser), :worktree}
  defp where_key(chooser, %Key{code: "c"}), do: {:start, name(chooser), :checkout}

  defp where_key(chooser, %Key{code: "enter"}),
    do: {:start, name(chooser), if(chooser.where == 0, do: :worktree, else: :checkout)}

  defp where_key(chooser, _key), do: {:ok, chooser}

  defp name(chooser), do: selected(chooser)["name"]
  defp selected(chooser), do: Enum.at(chooser.rows, chooser.cursor) || %{}

  # An agent the session cannot run is not started nor switched to: its reason is on its
  # row, and said again on the picker's line. Nor is a subagent, which only an agent's
  # delegation starts.
  defp runnable(chooser) do
    case selected(chooser) do
      %{"skipped" => true} = row ->
        {:refused, skipped_words(row)}

      %{"available" => false, "name" => name} = row ->
        {:refused, "#{name} cannot run here: #{row["reason"] || "the daemon says so"}"}

      %{"mode" => "subagent", "name" => name} ->
        {:refused,
         "#{name} is a subagent: an agent hands work to it, and nothing starts one; " <>
           "n makes a primary agent from it"}

      %{"name" => _name} = row ->
        {:ok, row}

      _none ->
        :none
    end
  end

  # `/new`'s Enter: a session of its own on the agent, which starts no branch here.
  defp new_session(chooser) do
    case runnable(chooser) do
      {:ok, %{"name" => name}} -> {:new, name}
      {:refused, reason} -> {:ok, %{chooser | status: reason}}
      :none -> :close
    end
  end

  # The manager's own actions, done by `/agents`' page on the agent: copying, deleting and
  # reading it whole. Nothing is written on a pod, and a bundle's agent is the console's to
  # change, though it is copied from (`n`).
  defp manage(chooser, code) do
    case selected(chooser) do
      %{"skipped" => true} = row ->
        {:ok, %{chooser | status: skipped_words(row)}}

      %{"name" => name} when code == "v" ->
        {:manage, name, "v"}

      %{"name" => _name} when is_binary(chooser.read_only) ->
        {:ok, %{chooser | status: chooser.read_only}}

      %{"layer" => "bundle", "name" => name} = row ->
        {:ok, %{chooser | status: bundle_words(row, name)}}

      %{"name" => name} ->
        {:manage, name, code}

      _none ->
        {:ok, chooser}
    end
  end

  # A new agent from the one selected, whichever it is: Troupe's own, the organisation's,
  # a person's or the repository's. It is written into a layer the person writes, so on a
  # pod, where nothing is, it is refused.
  defp new_from(chooser) do
    case selected(chooser) do
      %{"skipped" => true} = row ->
        {:ok, %{chooser | status: skipped_words(row)}}

      %{"name" => _name} when is_binary(chooser.read_only) ->
        {:ok, %{chooser | status: chooser.read_only}}

      %{"name" => name} ->
        {:new_from, name}

      _none ->
        {:ok, chooser}
    end
  end

  defp skipped_words(row),
    do: "#{row["path"]} is not read (#{row["reason"]}): e opens it to mend it"

  defp bundle_words(row, name),
    do:
      row["editable_reason"] ||
        "#{name} comes from the profile's bundle; change it in the console, or n makes " <>
          "an agent of your own from it"

  defp start(chooser) do
    with nil <- chooser.start,
         {:ok, _row} <- runnable(chooser) do
      {:ok, %{chooser | step: :where, status: nil}}
    else
      reason when is_binary(reason) -> {:ok, %{chooser | status: reason}}
      {:refused, reason} -> {:ok, %{chooser | status: reason}}
      :none -> :close
    end
  end

  defp switch(%{window: nil} = chooser),
    do:
      {:ok,
       %{
         chooser
         | status:
             "s switches a window's agent: Tab in the window opens this picker for it, " <>
               "and b starts a branch here"
       }}

  defp switch(chooser) do
    case runnable(chooser) do
      {:ok, %{"name" => name}} -> {:switch, name, chooser.window}
      {:refused, reason} -> {:ok, %{chooser | status: reason}}
      :none -> :close
    end
  end

  # A bundle's agent is changed in the console, and on a pod every agent is the bundle's;
  # a built-in is edited as a copy, which the save puts where the person says.
  defp edit(chooser) do
    case selected(chooser) do
      %{"name" => _name} when is_binary(chooser.read_only) ->
        {:ok, %{chooser | status: chooser.read_only}}

      %{"layer" => "bundle", "name" => name} = row ->
        {:ok, %{chooser | status: bundle_words(row, name)}}

      %{"name" => name} ->
        {:manage, name, "e"}

      _none ->
        :close
    end
  end

  defp move(chooser, by, sid) do
    last = max(length(chooser.rows) - 1, 0)
    cursor = chooser.cursor |> Kernel.+(by) |> max(0) |> min(last)
    fetch(%{chooser | cursor: cursor, status: nil}, sid)
  end

  # The highlighted agent read whole once, for its instruction.
  defp fetch(chooser, sid) do
    case Enum.at(chooser.rows, chooser.cursor) do
      %{"name" => name} when not is_map_key(chooser.details, name) ->
        case Client.agents(sid, "agents.get", %{name: name}) do
          {:ok, whole} -> %{chooser | details: Map.put(chooser.details, name, whole)}
          {:error, _reason} -> chooser
        end

      _other ->
        chooser
    end
  end

  @doc "Where a row's agent comes from, in the four words, from a daemon before them in its layer's."
  @spec origin(map()) :: String.t()
  def origin(%{"skipped" => true}), do: "not read"
  def origin(%{"origin" => origin}) when is_binary(origin), do: origin
  def origin(%{"layer" => "builtin"}), do: "Shipped"
  def origin(%{"layer" => "bundle"}), do: "Your organisation's"
  def origin(%{"layer" => "user"}), do: "Yours"
  def origin(%{"layer" => "project"}), do: "This repository's"
  def origin(row), do: Agents.layer_word(row["layer"])

  @doc """
  The popup's widgets, centred in `area` above `bottom` (the row where the command box
  starts); `running` is which windows run each agent now, which the manager's density says.
  """
  @spec render(t(), Rect.t(), non_neg_integer(), %{optional(String.t()) => [String.t()]}) ::
          [{term(), Rect.t()}]
  def render(chooser, area, bottom, running \\ %{}) do
    top_height = max(bottom - 1, 3)
    # The manager's density has more to say on each row, and takes the room the page had.
    {most_w, most_h, list_share} =
      if chooser.density == :manager, do: {200, 60, 11}, else: {120, 28, 9}

    width = area.width |> Kernel.-(4) |> min(most_w) |> max(min(area.width, 24))
    height = top_height |> Kernel.-(2) |> min(most_h) |> max(min(top_height, 6))

    rect = %Rect{
      x: div(area.width - width, 2),
      y: max(div(top_height - height, 2), 0),
      width: width,
      height: height
    }

    [list_rect, detail_rect] =
      if width >= 90,
        do: Layout.split(rect, :horizontal, [{:fill, list_share}, {:fill, 9}]),
        else: Layout.split(rect, :vertical, [{:fill, 1}, {:length, min(9, div(height, 2))}])

    name_w = chooser.rows |> Enum.map(&String.length(&1["name"])) |> Enum.max(fn -> 6 end)
    origin_w = chooser.rows |> Enum.map(&String.length(origin(&1))) |> Enum.max(fn -> 7 end)

    list = %ExRatatui.Widgets.List{
      items:
        Enum.map(
          chooser.rows,
          &row_line(&1, chooser.current, name_w, origin_w, chooser.density, running)
        ),
      selected: chooser.cursor,
      highlight_symbol: "▸ ",
      highlight_style: Theme.style(:accent, [:bold]),
      block: %Block{title: title(chooser), borders: [:all], border_type: :double}
    }

    detail = %Paragraph{
      text: detail(chooser, detail_rect, running),
      wrap: true,
      block: %Block{title: footer(chooser), borders: [:all]}
    }

    [{%Clear{}, rect}, {list, list_rect}, {detail, detail_rect}]
  end

  # Where nothing is written (a pod), the title says so, as the manager's page did.
  defp title(%{read_only: reason, title: title}) when is_binary(reason),
    do: String.trim_trailing(title) <> " · read-only here "

  defp title(chooser), do: chooser.title

  # The keys, the one Enter takes first.
  defp footer(%{step: :where}), do: " w worktree · c checkout · Enter the one marked · Esc back "

  defp footer(%{for: {:window, _path}}),
    do: " Enter/s switches · b starts a branch · e edits · n new from it · Esc keeps it "

  defp footer(%{for: {:new, _kind}}),
    do: " Enter starts a session on it · e edits · n new from it · Esc "

  defp footer(%{for: :manage}),
    do: " Enter reads it · b starts · e edit · c copy · n new from it · x delete · r reload · Esc "

  defp footer(%{window: nil}), do: " Enter/b starts · e edits · n new from it · Esc "
  defp footer(_chooser), do: " Enter/b starts · s switches · e edits · n new from it · Esc "

  # The agent in use is marked ahead of the rest of its row, where a narrow popup still
  # shows it. The manager's row says more: its mode, its facts as `/agents` has always
  # listed them, and what it stands in for.
  defp row_line(%{"skipped" => true} = row, _current, name_w, origin_w, _density, _running) do
    Line.new([
      Span.new(String.pad_trailing(row["name"], name_w + 3), style: Theme.style(:muted, [:bold])),
      Span.new(String.pad_trailing("not read", origin_w), style: Theme.style(:error)),
      Span.new(" · " <> to_string(row["reason"]), style: Theme.style(:muted))
    ])
  end

  defp row_line(row, current, name_w, origin_w, density, running) do
    style = if row["available"] == false, do: Theme.style(:muted), else: Theme.style(nil)
    now = if row["name"] == current, do: "● ", else: "  "

    facts =
      case density do
        :manager ->
          [mode_word(row["mode"]) | Agents.facts(row)] ++
            stands_in(row) ++ runs_in(Map.get(running, row["name"], []))

        _picker ->
          Agents.badges(row)
      end

    Line.new([
      Span.new(String.pad_trailing(row["name"], name_w + 1),
        style: Map.put(style, :modifiers, [:bold])
      ),
      Span.new(now, style: Theme.style(:ok, [:bold])),
      Span.new(String.pad_trailing(origin(row), origin_w), style: Agents.layer_style(row["layer"])),
      Span.new(" · " <> Enum.join(facts, " · "), style: style)
    ])
  end

  defp mode_word("subagent"), do: "subagent"
  defp mode_word(_primary), do: "primary"

  defp stands_in(%{"overrides" => [_ | _] = files}),
    do: ["stands in for " <> Enum.map_join(files, ", ", &(&1["origin"] || &1["layer"]))]

  defp stands_in(_row), do: []

  defp runs_in([]), do: []
  defp runs_in(windows), do: ["runs in " <> Enum.join(windows, ", ")]

  defp detail(%{step: :where} = chooser, _rect, _running) do
    marks = fn n -> if chooser.where == n, do: "▸ ", else: "  " end

    Enum.join(
      [
        "where #{name(chooser)} works:",
        "",
        marks.(0) <> "a worktree of its own (w): a branch and checkout of its own",
        marks.(1) <> "the checkout (c): this session's files, shared"
      ],
      "\n"
    )
  end

  defp detail(chooser, rect, running) do
    case Enum.at(chooser.rows, chooser.cursor) do
      nil ->
        ""

      %{"skipped" => true} = row ->
        Enum.join([skipped_words(row)] ++ status(chooser), "\n")

      row ->
        whole = Map.get(chooser.details, row["name"], row)

        # The manager's density says what the manager's page always has.
        facts =
          case chooser.density do
            :manager ->
              Agents.fields(whole, Map.get(running, row["name"], [])) ++
                not_editable(chooser, whole)

            _picker ->
              ["may: " <> Agents.permission_words(whole["permissions"])]
          end

        head =
          [String.trim(to_string(whole["description"] || "")), ""] ++
            from_words(row) ++ facts ++ cannot(row) ++ status(chooser)

        width = max(rect.width - 2, 1)

        used =
          head
          |> Enum.flat_map(&String.split(&1, "\n"))
          |> Enum.map(&Model.height(&1, width, :word))
          |> Enum.sum()

        room = max(rect.height - 2 - used - 2, 0)

        lines =
          whole["prompt"]
          |> to_string()
          |> Model.sanitize()
          |> String.split("\n")
          |> Enum.map(&("│ " <> &1))

        Enum.join(head ++ ["", "#{row["name"]} — its instruction:"] ++ Enum.take(lines, room), "\n")
    end
  end

  # Where it comes from, the profile a bundle's came with, and what it stands in for.
  defp from_words(row) do
    profile = if is_binary(row["profile"]), do: " (the #{row["profile"]} profile)", else: ""

    over =
      case row["overrides"] do
        [_ | _] = files ->
          ["stands in for: " <> Enum.map_join(files, ", ", &(&1["origin"] || &1["layer"]))]

        _none ->
          []
      end

    ["from: " <> origin(row) <> profile] ++ over
  end

  defp not_editable(%{read_only: reason}, _whole) when is_binary(reason), do: ["", reason]

  defp not_editable(_chooser, %{"editable" => false, "editable_reason" => reason})
       when is_binary(reason),
       do: ["", reason]

  defp not_editable(_chooser, _whole), do: []

  defp cannot(%{"available" => false} = row), do: ["", "cannot run here: #{row["reason"]}"]
  defp cannot(_row), do: []

  defp status(%{status: nil}), do: []
  defp status(%{status: status}), do: ["", status]
end
