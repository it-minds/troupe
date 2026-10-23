defmodule Troupe.UI.TUI.Agents do
  @moduledoc """
  The manager's page (issue #503, TUI Decision 156), which `/agents` and the agent picker
  open on an agent for what they do to it: `/agents` itself is the picker at the manager's
  density (`Troupe.UI.TUI.AgentChooser`), and its edit, copy, new and delete are done here
  and come back to it. Every agent the session's
  workspace has, with what decides whether a person wants one — where it comes from,
  its model, how many tools it holds, whether it is read-only, its cap on turns and which
  windows run it now — and each one's whole instruction. An agent is copied, created,
  edited and deleted here, always through the daemon (`agents.*`, root Decision 841),
  which checks it and writes it into the layer the person picks: theirs
  (`<config>/agents/`) or the repository's (`.troupe/agents/`).

  An edit is the person's own editor on a temporary copy of the file
  (`Troupe.Client.edit_file/2`). What comes back is checked at once; one the daemon
  would refuse is kept here, with its errors, and the next `e` opens it again rather
  than the file, so nothing typed is lost to a typo. Before anything is written the save
  says what the agent may do, every `auto` by name, and asks once more when the save
  adds an `auto` the name did not have — or takes one out of trust's reach, since an
  `auto` in the person's own layer applies in every workspace, trusted or not.

  A bundle's agent is the profile's and is changed in the console; on a pod every agent
  is the bundle's, and the page is read-only and says so.

  The subagents an agent delegates to are listed too, each saying it is one, and are
  edited and copied as any other (root Decision 852). A save goes with the `hash` of the
  file the edit was opened from, so one over a file somebody else saved meanwhile is
  refused with the daemon's sentence and the edit kept; the next save replaces theirs.
  Another client's save of the agent being edited is said as it is announced. A file that
  does not parse is opened by `e` like any other, and saved back where it is.

  The page is a map in the server's state (`agents_page`); `key/3` is its keys, and
  `render/3` its widgets. An edit is the one thing the server does for it, because the
  editor has the terminal: `key/3` answers `{:edit, page, request}`, and the server
  hands the outcome back to `edited/4`.
  """

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.TUI.{Model, Theme}

  @typedoc """
  The page: the listing (`rows`, the files not read in `skipped`, and `read_only`, why
  nothing here may be written, on a pod), the cursor, each agent read whole as the cursor
  reaches it (`details`), the instruction being read (`view`), the edits not saved yet
  with what was wrong with them and the file each was opened from (`kept`, `errors`,
  `bases`), the agent last saved (`saved`, which the picker comes back to), the question
  open (`ask`) and the page's own line of news (`status`).
  """
  @type page :: %{
          required(:rows) => [map()],
          required(:skipped) => [map()],
          required(:read_only) => String.t() | nil,
          required(:cursor) => non_neg_integer(),
          required(:details) => %{optional(String.t()) => map()},
          required(:view) => %{name: String.t(), scroll: non_neg_integer()} | nil,
          required(:kept) => %{optional(String.t()) => String.t()},
          required(:errors) => %{optional(String.t()) => [map()]},
          optional(:bases) => %{optional(String.t()) => base()},
          optional(:saved) => String.t() | nil,
          required(:ask) => map() | nil,
          required(:status) => String.t() | nil
        }

  @typedoc """
  The file an edit was opened from: its layer and the `hash` `agents.get` gave, sent as
  `if_hash` when the edit is saved back into that layer (root Decision 852).
  """
  @type base :: %{layer: String.t() | nil, hash: String.t() | nil} | nil

  @typedoc """
  An edit for the server to run: the agent's name, the text the editor opens on and the
  file it came from; `mend?` for a file that does not parse, saved back where it is;
  `from`, the agent a new one is made from.
  """
  @type request :: %{
          required(:name) => String.t(),
          required(:text) => String.t(),
          required(:kept?) => boolean(),
          required(:new?) => boolean(),
          optional(:base) => base(),
          optional(:mend?) => boolean(),
          optional(:from) => String.t()
        }

  ## Opening and reading

  @doc "The page for a session, its listing read now, the cursor on `select` when it is listed."
  @spec open(String.t(), String.t() | nil) :: page()
  def open(sid, select \\ nil) do
    %{
      rows: [],
      skipped: [],
      read_only: nil,
      cursor: 0,
      details: %{},
      view: nil,
      kept: %{},
      errors: %{},
      bases: %{},
      ask: nil,
      status: nil
    }
    |> reload(sid, select)
  end

  @doc """
  Reads the listing again, the subagents with the primaries, keeping the cursor on the
  agent it was on (or on `select`) and the edits not saved yet; what was read whole is
  read again as it is reached.
  """
  @spec reload(page(), String.t(), String.t() | nil) :: page()
  def reload(page, sid, select \\ nil) do
    select = select || selected_name(page)

    page =
      case Client.agents(sid, "agents.list", %{subagents: true}) do
        {:ok, listed} ->
          %{
            page
            | rows: List.wrap(listed["agents"]),
              skipped: List.wrap(listed["skipped"]),
              read_only: listed["read_only"],
              details: %{}
          }

        {:error, reason} ->
          %{page | rows: [], skipped: [], details: %{}, status: "agents.list: #{message(reason)}"}
      end

    cursor =
      Enum.find_index(entries(page), &(entry_name(&1) == select)) ||
        min(page.cursor, max(length(entries(page)) - 1, 0))

    fetch_selected(%{page | cursor: cursor}, sid)
  end

  @doc """
  What the page lists, in order: the agents, then the files that were found and not read
  (a definition that does not parse), each with why. What the cursor indexes.
  """
  @spec entries(page()) :: [{:agent, map()} | {:skipped, map()}]
  def entries(page),
    do: Enum.map(page.rows, &{:agent, &1}) ++ Enum.map(page.skipped, &{:skipped, &1})

  defp selected(page), do: Enum.at(entries(page), page.cursor)

  defp selected_name(page) do
    case selected(page) do
      nil -> nil
      entry -> entry_name(entry)
    end
  end

  defp entry_name({_kind, %{"name" => name}}), do: name
  defp entry_name({_kind, _entry}), do: nil

  # The selected agent read whole, once: its instruction, its file and the windows of the
  # session's family that run it. A file not read is asked about by its name too, for the
  # text of one that does not parse (`broken`), which `e` opens to mend.
  defp fetch_selected(page, sid) do
    case selected(page) do
      {:agent, %{"name" => name}} when not is_map_key(page.details, name) ->
        case Client.agents(sid, "agents.get", %{name: name}) do
          {:ok, whole} -> %{page | details: Map.put(page.details, name, whole)}
          {:error, reason} -> %{page | status: "agents.get #{name}: #{message(reason)}"}
        end

      {:skipped, %{"name" => name}} when is_binary(name) and not is_map_key(page.details, name) ->
        case Client.agents(sid, "agents.get", %{name: name}) do
          {:ok, whole} -> %{page | details: Map.put(page.details, name, whole)}
          {:error, _none} -> page
        end

      _other ->
        page
    end
  end

  defp bases(page), do: Map.get(page, :bases, %{})

  # What `e` on a file not read can open: the person's or the repository's that does not
  # parse, as `agents.get` answered it.
  defp broken(page, %{"name" => name}) when is_binary(name) do
    case get_in(page.details, [name, "broken"]) do
      %{"text" => text, "scope" => scope} = broken when is_binary(text) and is_binary(scope) ->
        broken

      _none ->
        nil
    end
  end

  defp broken(_page, _skipped), do: nil

  ## Keys

  @doc """
  One key on the page. `{:ok, page}` stays, `{:close, page}` leaves it, `{:edit, page,
  request}` asks the server to open the editor, and `{:changed, page}` says an agent was
  written or taken away, so the palette's rows are read again.
  """
  @spec key(page(), Key.t(), String.t()) ::
          {:ok, page()} | {:close, page()} | {:edit, page(), request()} | {:changed, page()}
  def key(%{ask: %{kind: :name}} = page, key, sid), do: name_key(page, key, sid)
  def key(%{ask: %{kind: :save}} = page, key, sid), do: save_key(page, key, sid)
  def key(%{ask: %{kind: :delete}} = page, key, sid), do: delete_key(page, key, sid)
  def key(%{view: %{}} = page, key, _sid), do: view_key(page, key)

  def key(page, %Key{code: "esc"}, _sid), do: {:close, page}
  def key(page, %Key{code: "q"}, _sid), do: {:close, page}

  def key(page, %Key{code: code}, sid) when code in ["up", "k"],
    do: {:ok, move(page, -1, sid)}

  def key(page, %Key{code: code}, sid) when code in ["down", "j"],
    do: {:ok, move(page, 1, sid)}

  def key(page, %Key{code: "page_up"}, sid), do: {:ok, move(page, -10, sid)}
  def key(page, %Key{code: "page_down"}, sid), do: {:ok, move(page, 10, sid)}
  def key(page, %Key{code: "home"}, sid), do: {:ok, move(page, -1_000_000, sid)}
  def key(page, %Key{code: "end"}, sid), do: {:ok, move(page, 1_000_000, sid)}
  def key(page, %Key{code: "r"}, sid), do: {:ok, %{reload(page, sid) | status: "read again"}}

  def key(page, %Key{code: code}, _sid) when code in ["enter", "v"] do
    case selected(page) do
      {:agent, %{"name" => name}} -> {:ok, %{page | view: %{name: name, scroll: 0}}}
      _other -> {:ok, page}
    end
  end

  def key(page, %Key{code: "e"}, _sid), do: edit(page)
  def key(page, %Key{code: "c"}, sid), do: copy(page, sid)
  def key(page, %Key{code: "x"}, _sid), do: ask_delete(page)

  def key(page, %Key{code: "n"}, _sid) do
    case page.read_only do
      nil -> {:ok, %{page | ask: %{kind: :name, text: ""}, status: nil}}
      reason -> {:ok, %{page | status: reason}}
    end
  end

  # A kept edit can be let go of, so the next `e` opens the file as it is.
  def key(page, %Key{code: "z"}, _sid) do
    case selected_name(page) do
      name when is_map_key(page.kept, name) ->
        {:ok,
         page
         |> Map.merge(%{
           kept: Map.delete(page.kept, name),
           errors: Map.delete(page.errors, name),
           bases: Map.delete(bases(page), name),
           status: "dropped your edit of #{name}; e opens its file as it is"
         })}

      _other ->
        {:ok, page}
    end
  end

  def key(page, _key, _sid), do: {:ok, page}

  defp move(page, by, sid) do
    last = max(length(entries(page)) - 1, 0)
    fetch_selected(%{page | cursor: page.cursor |> Kernel.+(by) |> max(0) |> min(last)}, sid)
  end

  # Reading the whole instruction: the arrows and pages scroll it, Esc goes back to the list.
  defp view_key(page, %Key{code: code}) when code in ["esc", "q", "enter", "v"],
    do: {:ok, %{page | view: nil}}

  defp view_key(page, %Key{code: code}) when code in ["up", "k"], do: {:ok, scroll(page, -1)}
  defp view_key(page, %Key{code: code}) when code in ["down", "j"], do: {:ok, scroll(page, 1)}
  defp view_key(page, %Key{code: "page_up"}), do: {:ok, scroll(page, -20)}
  defp view_key(page, %Key{code: "page_down"}), do: {:ok, scroll(page, 20)}
  defp view_key(page, %Key{code: "home"}), do: {:ok, %{page | view: %{page.view | scroll: 0}}}
  defp view_key(page, %Key{code: "e"}), do: edit(%{page | view: nil})
  defp view_key(page, _key), do: {:ok, page}

  # Never past the instruction's last line; the drawing stops at its last screenful.
  defp scroll(%{view: view} = page, by) do
    lines = page.details |> get_in([view.name, "prompt"]) |> to_string() |> String.split("\n")
    %{page | view: %{view | scroll: view.scroll |> Kernel.+(by) |> max(0) |> min(length(lines))}}
  end

  ## Editing

  # The file as it is, or the edit kept from the last try. A built-in is edited too: what
  # is saved is a copy in a layer the person picks, which then answers to the name. A
  # bundle's agent is the profile's, and a pod's are all the bundle's. The file the edit
  # comes from goes with it, so its save can say which file it means to replace.
  defp edit(page) do
    with :ok <- writable(page),
         {:agent, %{"name" => name} = row} <- selected(page) || :none,
         :ok <- not_bundle(page, row) do
      case Map.fetch(page.kept, name) do
        {:ok, text} ->
          {:edit, page,
           %{name: name, text: text, kept?: true, new?: false, base: bases(page)[name]}}

        :error ->
          whole = Map.get(page.details, name, %{})

          case whole["text"] do
            text when is_binary(text) ->
              base = %{layer: whole["layer"], hash: whole["hash"]}
              {:edit, page, %{name: name, text: text, kept?: false, new?: false, base: base}}

            _none ->
              {:ok, %{page | status: "#{name} has no file to edit here"}}
          end
      end
    else
      {:skipped, skipped} -> mend(page, skipped)
      {:refused, reason} -> {:ok, %{page | status: reason}}
      _none -> {:ok, page}
    end
  end

  # A file that does not parse, opened as it is (or as the last try left it) and saved
  # back where it is (root Decision 852); one not read for another reason is the hand's.
  defp mend(page, skipped) do
    case broken(page, skipped) do
      nil ->
        {:ok, %{page | status: skipped_words(page, skipped)}}

      broken ->
        name = skipped["name"]
        base = Map.get(bases(page), name) || %{layer: broken["scope"], hash: broken["hash"]}

        {text, kept?} =
          case Map.fetch(page.kept, name) do
            {:ok, kept} -> {kept, true}
            :error -> {broken["text"], false}
          end

        {:edit, page, %{name: name, text: text, kept?: kept?, new?: false, base: base, mend?: true}}
    end
  end

  defp writable(%{read_only: nil}), do: :ok
  defp writable(%{read_only: reason}), do: {:refused, reason}

  defp not_bundle(page, %{"layer" => "bundle", "name" => name}),
    do:
      {:refused,
       get_in(page.details, [name, "editable_reason"]) ||
         "#{name} is the profile's bundle's: change it in the console"}

  defp not_bundle(_page, _row), do: :ok

  @doc """
  What the editor gave back, for an edit `key/3` asked for: an editor that failed, or a
  file left as it was, writes nothing; anything else is checked by the daemon, and either
  kept with its errors or taken to the save question.
  """
  @spec edited(page(), String.t(), request(), {:ok, String.t()} | {:error, String.t()}) :: page()
  def edited(page, _sid, _request, {:error, reason}),
    do: %{page | status: "the editor: " <> reason}

  # A new agent made from another is saved unchanged too: the copy is what was asked for.
  def edited(page, _sid, %{text: text, kept?: false} = request, {:ok, text})
      when not is_map_key(request, :from) do
    what = if request.new?, do: "the new agent #{request.name}", else: request.name
    %{page | status: "#{what}: nothing changed, so nothing is saved"}
  end

  def edited(page, sid, %{name: name} = request, {:ok, text}) do
    case Client.agents(sid, "agents.validate", %{name: name, source: text}) do
      {:ok, %{"ok" => true} = checked} ->
        ask_save(%{page | errors: Map.delete(page.errors, name)}, sid, request, text, checked)

      {:ok, %{"errors" => errors}} ->
        page
        |> keep(name, text, request[:base])
        |> Map.merge(%{
          errors: Map.put(page.errors, name, errors),
          ask: nil,
          status: "#{name} is not saved: #{first_error(errors)}; e opens your edit again"
        })

      {:error, reason} ->
        page
        |> keep(name, text, request[:base])
        |> Map.put(:status, "#{name} could not be checked: #{message(reason)}; your edit is kept")
    end
  end

  # An edit not saved, kept with the file it was opened from.
  defp keep(page, name, text, base) do
    Map.merge(page, %{kept: Map.put(page.kept, name, text), bases: Map.put(bases(page), name, base)})
  end

  defp first_error([%{"field" => field, "message" => message} | rest]) do
    more = if rest == [], do: "", else: " (and #{length(rest)} more)"
    "#{field}: #{message}#{more}"
  end

  defp first_error(_none), do: "the daemon refused it"

  ## Saving

  # The save question: which layer, and what the agent may do. The permissions are the
  # text's own; what the name has now (any layer) is what an `auto` is compared with. A
  # file that did not parse is saved back where it is, and since nothing of it was read,
  # every `auto` in it counts.
  defp ask_save(page, sid, request, text, checked) do
    current =
      case Client.agents(sid, "agents.get", %{name: request.name}) do
        {:ok, whole} -> whole
        {:error, _not_found} -> nil
      end

    mend? = request[:mend?] == true
    base = request[:base]

    ask = %{
      kind: :save,
      name: request.name,
      source: text,
      layer: if(mend?, do: base && base.layer, else: current && current["layer"]),
      before: if(mend?, do: %{}, else: (current && current["permissions"]) || %{}),
      base: base,
      permissions: permissions(text),
      warnings: List.wrap(checked["warnings"]),
      confirm: nil
    }

    %{page | ask: ask, status: nil}
  end

  # Copying is one key: into the repository, under the same name, which then answers to it
  # there; the repository's own is copied into the person's layer. It is a save like any
  # other, so the question says what the agent may do before anything is written.
  defp copy(page, sid) do
    with :ok <- writable(page),
         {:agent, %{"name" => name} = row} <- selected(page) || :none,
         :ok <- not_bundle(page, row),
         text when is_binary(text) <- get_in(page.details, [name, "text"]) || :no_file do
      scope = if row["layer"] == "project", do: "user", else: "project"

      page
      |> ask_save(sid, %{name: name, text: text, kept?: false, new?: false}, text, %{})
      |> picked(sid, scope)
    else
      {:skipped, skipped} -> {:ok, %{page | status: skipped_words(page, skipped)}}
      {:refused, reason} -> {:ok, %{page | status: reason}}
      :no_file -> {:ok, %{page | status: "#{selected_name(page)} has no file to copy here"}}
      _none -> {:ok, page}
    end
  end

  defp save_key(page, %Key{code: "esc"}, _sid), do: {:ok, keep_edit(page)}

  defp save_key(%{ask: %{confirm: scope}} = page, %Key{code: "y"}, sid) when is_binary(scope),
    do: put(page, sid, scope)

  defp save_key(%{ask: %{confirm: scope} = ask} = page, _key, _sid) when is_binary(scope),
    do: {:ok, %{page | ask: %{ask | confirm: nil}}}

  defp save_key(page, %Key{code: "r"}, sid), do: picked(page, sid, "project")
  defp save_key(page, %Key{code: "m"}, sid), do: picked(page, sid, "user")

  defp save_key(%{ask: %{layer: layer}} = page, %Key{code: "enter"}, sid)
       when layer in ["user", "project"],
       do: picked(page, sid, layer)

  defp save_key(page, _key, _sid), do: {:ok, page}

  # A layer picked: saved at once when it adds no `auto`, asked once more when it does.
  # Only a save that wrote is `:changed`: one refused keeps the edit on the page.
  defp picked(%{ask: ask} = page, sid, scope) do
    case widened(ask, scope) do
      [] -> put(page, sid, scope)
      _tools -> {:ok, %{page | ask: %{ask | confirm: scope}}}
    end
  end

  @doc """
  The tools a save into `scope` lets run without asking that did not before, compared
  with the file it replaces, as the desktop app compares (root Decision 842): the agent
  answering to the name now when it is in that layer, an `auto` added or an `ask` or `deny`
  made `auto`; anything else is a new file there, and every `auto` in it counts. So a copy
  from the repository's layer, where an `auto` waits for the workspace to be trusted, into
  the person's, where it does not, is asked about.
  """
  @spec widened(map(), String.t()) :: [String.t()]
  def widened(%{permissions: permissions, before: before, layer: layer}, scope) do
    replaced = if layer == scope, do: before, else: %{}
    for {tool, "auto"} <- Enum.sort(permissions), Map.get(replaced, tool) != "auto", do: tool
  end

  # Saved back into the layer the edit was opened from, the save names that file's hash,
  # and one somebody else saved meanwhile is refused (root Decision 852).
  defp put(%{ask: ask} = page, sid, scope) do
    params =
      case Map.get(ask, :base) do
        %{layer: ^scope, hash: hash} when is_binary(hash) -> %{if_hash: hash}
        _other -> %{}
      end

    case Client.agents(
           sid,
           "agents.put",
           Map.merge(params, %{name: ask.name, scope: scope, source: ask.source})
         ) do
      {:ok, written} ->
        warnings = written |> Map.get("warnings") |> List.wrap() |> Enum.map(& &1["message"])

        page =
          Map.merge(page, %{
            ask: nil,
            kept: Map.delete(page.kept, ask.name),
            errors: Map.delete(page.errors, ask.name),
            bases: Map.delete(bases(page), ask.name),
            saved: ask.name
          })

        page = reload(page, sid, ask.name)

        status =
          Enum.join(
            [
              "#{written["action"] || "saved"} #{ask.name} in #{layer_place(scope)} (#{written["path"]})"
            ] ++
              warnings,
            " · "
          )

        {:changed, %{page | status: status}}

      {:error, "conflict: " <> sentence} ->
        # The person has been told; the edit is kept, and its next save is over the file
        # as it is now.
        {:ok,
         page
         |> keep(ask.name, ask.source, %{layer: scope, hash: hash_now(sid, ask.name, scope)})
         |> Map.merge(%{
           ask: nil,
           status:
             "#{ask.name} is not saved: #{sentence}. Your edit is kept: e opens it, z drops it"
         })}

      {:error, reason} ->
        {:ok,
         page
         |> keep(ask.name, ask.source, Map.get(ask, :base))
         |> Map.merge(%{
           ask: nil,
           status: "#{ask.name} is not saved: #{message(reason)}; e opens your edit again"
         })}
    end
  end

  # The hash of the name's file in a layer now, as `agents.get` reads it: the one that
  # answers, or one there that does not parse; `nil` when the layer has none.
  defp hash_now(sid, name, scope) do
    case Client.agents(sid, "agents.get", %{name: name}) do
      {:ok, %{"layer" => ^scope, "hash" => hash}} -> hash
      {:ok, %{"broken" => %{"scope" => ^scope, "hash" => hash}}} -> hash
      _none -> nil
    end
  end

  # Esc on the save question keeps the text for the next `e`; a copy has nothing of the
  # person's to keep.
  defp keep_edit(%{ask: ask} = page) do
    text = get_in(page.details, [ask.name, "text"])

    if ask.source == text do
      %{page | ask: nil, status: "nothing saved"}
    else
      page
      |> keep(ask.name, ask.source, Map.get(ask, :base))
      |> Map.merge(%{
        ask: nil,
        status: "kept your edit of #{ask.name}, not saved; e opens it again"
      })
    end
  end

  @doc """
  An `agents.changed` heard while the page is open: another client saved or took away an
  agent. One with an edit open here (kept, or at the save question) is said, since this
  edit's save is now over a file it was not opened from, and is refused once (root
  Decision 852). This client's own saves have closed their edit by the time theirs is
  heard.
  """
  @spec heard(page(), map()) :: page()
  def heard(page, %{"name" => name} = changed) when is_binary(name) do
    open? = Map.has_key?(page.kept, name) or match?(%{kind: :save, name: ^name}, page.ask)

    if open?,
      do: %{
        page
        | status:
            "#{name} was #{changed_verb(changed["action"])} elsewhere while you had it open " <>
              "(#{changed["path"]}): saving yours is refused once, so you can read it first; " <>
              "the next save replaces it"
      },
      else: page
  end

  def heard(page, _changed), do: page

  defp changed_verb("deleted"), do: "deleted"
  defp changed_verb(_saved), do: "saved"

  @doc """
  The `permissions:` a definition's frontmatter sets, `%{tool => "auto" | "ask" | "deny"}`,
  read as the daemon reads it; empty when it sets none or does not parse (which the
  daemon's check has said already).
  """
  @spec permissions(String.t()) :: %{optional(String.t()) => String.t()}
  def permissions(source) do
    with [_, front] <- Regex.run(~r/\A---\r?\n(.*?)\r?\n---/s, source),
         {:ok, %{"permissions" => %{} = permissions}} <- YamlElixir.read_from_string(front) do
      Map.new(permissions, fn {tool, value} -> {to_string(tool), to_string(value)} end)
    else
      _none -> %{}
    end
  end

  ## A new agent

  @template """
  ---
  description: What NAME is for, in one line; the palette shows it.
  mode: primary
  tools:
    - read_file
    - list_files
    - grep
    - glob
    - finish
  ---
  You are NAME. Say what you work on, how you go about it, and when you stop.
  """

  @doc "The text a new agent starts from: a read-only primary agent, to be made what it is for."
  @spec template(String.t()) :: String.t()
  def template(name), do: String.replace(@template, "NAME", name)

  @doc """
  The page asking for the name of a new agent made from `source`, which the picker's `n`
  opens (#594): the copy is the source's file as it is, a built-in's or the
  organisation's as well as a person's own, opened in the editor under the name typed and
  saved, like any new agent, into the layer the person picks. Unchanged, it is still saved:
  a copy of an agent that works is a new agent. Refused, with the listing's sentence, where
  nothing is written (a pod).
  """
  @spec new_from(page(), String.t(), String.t()) :: page()
  def new_from(%{read_only: reason} = page, _sid, _source) when is_binary(reason),
    do: %{page | status: reason}

  def new_from(page, sid, source) do
    page = %{page | view: nil, ask: %{kind: :name, text: "", from: source}, status: nil}

    case get_in(page.details, [source, "text"]) do
      text when is_binary(text) ->
        page

      _none ->
        case Client.agents(sid, "agents.get", %{name: source}) do
          {:ok, whole} -> %{page | details: Map.put(page.details, source, whole)}
          {:error, reason} -> %{page | ask: nil, status: "agents.get #{source}: #{message(reason)}"}
        end
    end
  end

  # The source's file, or one made from its fields where the daemon read it from nowhere it
  # gives back (an older daemon's bundle agent).
  defp source_text(page, source) do
    whole = Map.get(page.details, source, %{})

    case whole["text"] do
      text when is_binary(text) -> text
      _none -> written(whole)
    end
  end

  defp written(whole) do
    front =
      [
        {"description", whole["description"]},
        {"mode", whole["mode"] || "primary"},
        {"model", whole["model"]},
        {"max_turns", whole["max_turns"]}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} -> "#{key}: #{yaml_value(value)}" end)

    tools =
      case whole["tools"] do
        [_ | _] = tools -> ["tools:" | Enum.map(tools, &"  - #{&1}")]
        _all -> []
      end

    Enum.join(["---"] ++ front ++ tools ++ ["---", to_string(whole["prompt"])], "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml_value(value), do: to_string(value)

  defp name_key(page, %Key{code: "esc"}, _sid), do: {:ok, %{page | ask: nil}}

  defp name_key(%{ask: %{text: text}} = page, %Key{code: "backspace"}, _sid),
    do: {:ok, %{page | ask: %{page.ask | text: String.slice(text, 0..-2//1)}}}

  defp name_key(%{ask: %{text: text}} = page, %Key{code: "enter"}, _sid) do
    name = String.trim(text)

    cond do
      name == "" ->
        {:ok, page}

      Enum.any?(page.rows, &(&1["name"] == name)) ->
        {:ok, %{page | status: "#{name} is an agent already: e edits it, c copies it"}}

      true ->
        from = page.ask[:from]
        page = %{page | ask: nil}

        case {Map.fetch(page.kept, name), from} do
          {{:ok, kept}, _from} ->
            {:edit, page, %{name: name, text: kept, kept?: true, new?: true}}

          {:error, nil} ->
            {:edit, page, %{name: name, text: template(name), kept?: false, new?: true}}

          {:error, from} ->
            {:edit, page,
             %{name: name, text: source_text(page, from), kept?: false, new?: true, from: from}}
        end
    end
  end

  defp name_key(%{ask: %{text: text}} = page, %Key{code: code, modifiers: mods}, _sid)
       when mods in [[], ["shift"]] do
    if String.length(code) == 1,
      do: {:ok, %{page | ask: %{page.ask | text: text <> code}}},
      else: {:ok, page}
  end

  defp name_key(page, _key, _sid), do: {:ok, page}

  @doc "Text pasted while the page asks for a name goes into it."
  @spec paste(page(), String.t()) :: page()
  def paste(%{ask: %{kind: :name, text: text}} = page, content),
    do: %{page | ask: %{page.ask | text: text <> Model.one_line(content)}}

  def paste(page, _content), do: page

  ## Deleting

  # Only a file in one of the two layers the person writes is taken away, and the question
  # names which; what answers to the name after it is said once it has gone.
  defp ask_delete(page) do
    with :ok <- writable(page),
         {:agent, %{"name" => name} = row} <- selected(page) || :none,
         :ok <- not_bundle(page, row) do
      case row["layer"] do
        layer when layer in ["user", "project"] ->
          path = get_in(page.details, [name, "path"])
          {:ok, %{page | ask: %{kind: :delete, name: name, scope: layer, path: path}, status: nil}}

        _builtin ->
          {:ok,
           %{
             page
             | status:
                 "#{name} is built in and is not deleted: a copy of it in your layer or the " <>
                   "repository's replaces it, and deleting that copy brings it back"
           }}
      end
    else
      {:skipped, skipped} -> {:ok, %{page | status: skipped_words(page, skipped)}}
      {:refused, reason} -> {:ok, %{page | status: reason}}
      _none -> {:ok, page}
    end
  end

  defp delete_key(%{ask: ask} = page, %Key{code: "y"}, sid) do
    case Client.agents(sid, "agents.delete", %{name: ask.name, scope: ask.scope}) do
      {:ok, deleted} ->
        after_words =
          case deleted["layer"] do
            nil -> ""
            layer -> "; #{ask.name} now answers from #{layer_place(layer)}"
          end

        page = reload(%{page | ask: nil}, sid)

        {:changed,
         %{
           page
           | status:
               "deleted #{ask.name} from #{layer_place(ask.scope)} (#{deleted["path"]})" <>
                 after_words
         }}

      {:error, reason} ->
        {:ok, %{page | ask: nil, status: "#{ask.name} is not deleted: #{message(reason)}"}}
    end
  end

  defp delete_key(page, _key, _sid), do: {:ok, %{page | ask: nil, status: "nothing deleted"}}

  defp skipped_words(page, skipped) do
    case broken(page, skipped) do
      nil ->
        "#{skipped["path"]} is not read (#{skipped["reason"]}): fix the file by hand, " <>
          "and r reads it again"

      broken ->
        "#{skipped["path"]} is not read (#{skipped["reason"]}): e opens it to mend it, " <>
          "and the save puts it back in #{layer_place(broken["scope"])}"
    end
  end

  ## Words

  @doc "What a layer is called on the page, in the palette and in the chooser."
  @spec layer_word(String.t() | nil) :: String.t()
  def layer_word("builtin"), do: "built-in"
  def layer_word("bundle"), do: "bundle"
  def layer_word("user"), do: "mine"
  def layer_word("project"), do: "repository"
  def layer_word(nil), do: "?"
  def layer_word(other), do: other

  defp layer_place("builtin"), do: "the built-ins"
  defp layer_place("bundle"), do: "the profile's bundle"
  defp layer_place("user"), do: "your agents"
  defp layer_place("project"), do: "this repository"
  defp layer_place(other), do: to_string(other)

  @doc """
  An agent's facts in one run of text, for the list, the palette and the chooser: its
  model, how many tools it holds, whether it is read-only, its cap on turns, whether a
  session on it would get a worktree, and why it cannot run here when it cannot.
  """
  @spec facts(map(), keyword()) :: [String.t()]
  def facts(row, opts \\ []) do
    [
      row["model"] || "session's model",
      if(Keyword.get(opts, :tools, true) and is_integer(row["tool_count"]),
        do: "#{row["tool_count"]} tools"
      ),
      if(row["read_only"] == true, do: "read-only"),
      if(Keyword.get(opts, :turns, true) and is_integer(row["max_turns"]),
        do: "max #{row["max_turns"]} turns"
      ),
      if(Keyword.get(opts, :worktree, false),
        do: if(row["worktree"] == true, do: "own worktree", else: "this checkout")
      ),
      if(row["available"] == false, do: "cannot run: #{row["reason"]}")
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The same facts in as few cells as say them, for a row with little room (the palette's,
  the chooser's): its model (`default`, the session's), whether it is read-only, and
  whether a session on it gets a `worktree` or works in the `checkout`.
  """
  @spec badges(map()) :: [String.t()]
  def badges(row) do
    [
      row["model"] || "default",
      if(row["read_only"] == true, do: "read-only"),
      if(row["worktree"] == true, do: "worktree", else: "checkout")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  ## Drawing

  @doc "The page's widgets in `rect`: the list beside the selected agent, or one instruction whole."
  @spec render(page(), Rect.t(), map()) :: [{term(), Rect.t()}]
  def render(%{view: %{name: name, scroll: scroll}} = page, rect, _state) do
    whole = Map.get(page.details, name, %{})
    prompt = Model.sanitize(whole["prompt"] || "(no instruction)")
    width = max(rect.width - 2, 1)
    total = prompt |> String.split("\n") |> Enum.map(&Model.height(&1, width, :word)) |> Enum.sum()

    [
      {%Paragraph{
         text: prompt,
         wrap: true,
         scroll: {min(scroll, max(total - (rect.height - 2), 0)), 0},
         block: %Block{
           title:
             " #{name} — the whole instruction · #{whole["path"] || layer_word(whole["layer"])} ",
           borders: [:all],
           border_type: :double
         }
       }, rect}
    ]
  end

  def render(page, rect, state) do
    [list_rect, detail_rect] = Layout.split(rect, :horizontal, [{:fill, 11}, {:fill, 9}])
    running = running(state)
    entries = entries(page)
    name_w = entries |> Enum.map(&String.length(entry_name(&1) || "")) |> Enum.max(fn -> 6 end)

    items =
      case entries do
        [] -> [page.status || "No agents: the daemon answered none."]
        list -> Enum.map(list, &line(&1, page, running, name_w))
      end

    list = %ExRatatui.Widgets.List{
      items: items,
      selected: if(entries == [], do: nil, else: min(page.cursor, length(entries) - 1)),
      highlight_symbol: "▸ ",
      highlight_style: Theme.style(:accent, [:bold]),
      block: %Block{title: list_title(page), borders: [:all], border_type: :double}
    }

    detail = %Paragraph{
      text: detail(page, selected(page), running, detail_rect),
      wrap: true,
      block: %Block{title: detail_title(page), borders: [:all]}
    }

    [{list, list_rect}, {detail, detail_rect}]
  end

  defp list_title(%{read_only: nil, rows: rows}), do: " agents — #{length(rows)} "
  defp list_title(%{rows: rows}), do: " agents — #{length(rows)} · read-only here "

  defp detail_title(%{ask: %{kind: :save, name: name}}), do: " save #{name} "
  defp detail_title(%{ask: %{kind: :delete, name: name}}), do: " delete #{name} "
  defp detail_title(_page), do: " the agent "

  @doc "Which windows on the screen run each agent now: `%{agent => [window]}`."
  @spec running(map()) :: %{optional(String.t()) => [String.t()]}
  def running(%{model: %Model{} = model}),
    do: model |> Model.windows() |> Enum.group_by(& &1.profile, & &1.path)

  def running(_state), do: %{}

  defp line({:agent, row}, page, running, name_w) do
    name = row["name"]
    windows = Map.get(running, name, [])
    style = if row["available"] == false, do: Theme.style(:muted), else: Theme.style(nil)

    # A subagent says so first: nothing a person types starts one, an agent delegates to it.
    facts =
      if(row["mode"] == "subagent", do: ["subagent"], else: []) ++
        facts(row) ++
        if(windows == [], do: [], else: ["runs in " <> Enum.join(windows, ", ")]) ++
        if(Map.has_key?(page.kept, name), do: ["edit kept, not saved"], else: [])

    Line.new([
      Span.new(String.pad_trailing(name, name_w + 2), style: Map.put(style, :modifiers, [:bold])),
      Span.new(String.pad_trailing(layer_word(row["layer"]), 12), style: layer_style(row["layer"])),
      Span.new(Enum.join(facts, " · "), style: style)
    ])
  end

  defp line({:skipped, skipped}, _page, _running, name_w) do
    name = skipped["name"] || Path.basename(to_string(skipped["path"]))

    Line.new([
      Span.new(String.pad_trailing(name, name_w + 2), style: Theme.style(:muted, [:bold])),
      Span.new(String.pad_trailing("not read", 12), style: Theme.style(:error)),
      Span.new(to_string(skipped["reason"]), style: Theme.style(:muted))
    ])
  end

  @doc "The style a layer's badge is drawn in, the same wherever an agent's layer is shown."
  @spec layer_style(String.t() | nil) :: ExRatatui.Style.t()
  def layer_style("project"), do: Theme.style(:hunk)
  def layer_style("user"), do: Theme.style(:ok)
  def layer_style("bundle"), do: Theme.style(:working)
  def layer_style(_builtin), do: Theme.style(:muted)

  defp detail(%{ask: %{kind: :save} = ask}, _entry, _running, _rect), do: save_text(ask)
  defp detail(%{ask: %{kind: :delete} = ask}, _entry, _running, _rect), do: delete_text(ask)
  defp detail(page, nil, _running, _rect), do: page.status || "Nothing to show."

  defp detail(page, {:skipped, skipped}, _running, _rect),
    do: Enum.join([skipped_words(page, skipped)] ++ status_lines(page), "\n")

  defp detail(page, {:agent, %{"name" => name} = row}, running, rect) do
    whole = Map.get(page.details, name, row)

    head =
      [
        String.trim(to_string(whole["description"] || "")),
        "",
        field("from", layer_word(whole["layer"]) <> path_words(whole))
      ] ++
        fields(whole, Map.get(running, name, [])) ++
        hides(whole) ++
        notes(whole) ++
        not_editable(page, whole) ++
        kept_lines(page, name) ++ status_lines(page)

    instruction = Model.sanitize(to_string(whole["prompt"] || ""))
    width = max(rect.width - 2, 1)
    used = Enum.sum(Enum.map(head, &rows(&1, width))) + 3
    room = max(rect.height - 2 - used, 0)
    lines = instruction |> String.split("\n") |> Enum.map(&("│ " <> &1))
    shown = Enum.take(lines, room)

    more =
      case length(lines) - length(shown) do
        0 -> []
        n -> ["… #{n} more lines: Enter reads it whole"]
      end

    Enum.join(head ++ ["", "instruction:"] ++ shown ++ more, "\n")
  end

  @doc """
  What decides whether a person wants an agent, a line each, as the manager has always
  shown them: its mode, model, tools, what it may do, its cap on turns, the windows that
  run it and whether a session on it gets a worktree. The picker's manager density shows
  the same lines.
  """
  @spec fields(map(), [String.t()]) :: [String.t()]
  def fields(whole, windows) do
    [
      field("mode", mode_words(whole["mode"])),
      field("model", whole["model"] || "the session's"),
      field("tools", tools_words(whole)),
      field("may", permission_words(whole["permissions"])),
      field("max turns", whole["max_turns"] || "no cap of its own"),
      field("runs in", windows_words(windows)),
      field(
        "worktree",
        if(whole["worktree"] == true,
          do: "a session on it gets its own",
          else: "it works in this checkout"
        )
      )
    ]
  end

  defp rows(text, width),
    do: text |> String.split("\n") |> Enum.map(&Model.height(&1, width, :word)) |> Enum.sum()

  defp field(label, value), do: String.pad_trailing(label, 11) <> to_string(value)

  defp path_words(%{"path" => path}) when is_binary(path), do: " · " <> path
  defp path_words(_whole), do: ""

  defp mode_words("subagent"), do: "subagent: an agent delegates to it"
  defp mode_words(_primary), do: "primary: a session or a branch runs it"

  defp tools_words(%{"tools" => "all", "tool_count" => n}), do: "all (#{n})"

  defp tools_words(%{"tools" => tools}) when is_list(tools),
    do: "#{length(tools)}: " <> Enum.join(tools, ", ")

  defp tools_words(%{"tool_count" => n}) when is_integer(n), do: "#{n}"
  defp tools_words(_whole), do: "?"

  @doc """
  What a definition's permissions let it do, every `auto` first and by name, since those
  run without asking anyone.
  """
  @spec permission_words(map() | nil) :: String.t()
  def permission_words(permissions) when is_map(permissions) and map_size(permissions) > 0 do
    {auto, rest} = permissions |> Enum.sort() |> Enum.split_with(fn {_t, p} -> p == "auto" end)

    Enum.map_join(auto ++ rest, " · ", fn {tool, p} -> "#{tool} #{p}" end) <>
      if(auto == [], do: " (no auto)", else: "")
  end

  def permission_words(_none), do: "each tool's own default (no auto)"

  defp windows_words([]), do: "no window on this screen"
  defp windows_words(windows), do: Enum.join(windows, ", ")

  defp hides(%{"also" => [_ | _] = also}),
    do: [field("hides", Enum.map_join(also, ", ", &"#{layer_word(&1["layer"])} #{&1["path"]}"))]

  defp hides(_whole), do: []

  defp notes(%{"notes" => [_ | _] = notes}), do: Enum.map(notes, &field("note", &1["reason"]))
  defp notes(_whole), do: []

  defp not_editable(%{read_only: reason}, _whole) when is_binary(reason), do: ["", reason]

  defp not_editable(_page, %{"editable" => false, "editable_reason" => reason})
       when is_binary(reason),
       do: ["", reason]

  defp not_editable(_page, _whole), do: []

  defp kept_lines(page, name) do
    case {Map.has_key?(page.kept, name), Map.get(page.errors, name, [])} do
      {false, _} ->
        []

      {true, []} ->
        ["", "Your edit is kept, not saved: e opens it again, z drops it."]

      {true, errors} ->
        ["", "Your edit is kept, not saved. The daemon refused it:"] ++
          Enum.map(errors, &"  #{&1["field"]}: #{&1["message"]}") ++
          ["e opens it again to fix, z drops it."]
    end
  end

  defp status_lines(%{status: nil}), do: []
  defp status_lines(%{status: status}), do: ["", status]

  defp save_text(ask) do
    autos = for {tool, "auto"} <- Enum.sort(ask.permissions), do: tool

    may =
      case autos do
        [] -> ["It runs no tool without asking: nothing in its permissions is auto."]
        _ -> ["Without asking anyone it runs: " <> Enum.join(autos, ", ") <> "."]
      end

    warnings = Enum.map(ask.warnings, &"warning — #{&1["field"]}: #{&1["message"]}")

    choice =
      case ask.confirm do
        nil ->
          [
            "",
            "r  this repository (.troupe/agents/#{ask.name}.md): committed and shared; an auto " <>
              "there waits until the workspace is trusted",
            "m  mine (agents/#{ask.name}.md beside your config): every session on this " <>
              "machine reads it, and an auto there is not held back by trust",
            ""
          ] ++
            if(ask.layer in ["user", "project"],
              do: ["Enter saves it where it is (#{layer_word(ask.layer)}) · Esc keeps your edit"],
              else: ["Esc keeps your edit, not saved"]
            )

        scope ->
          runs = "lets #{ask.name} run #{Enum.join(widened(ask, scope), ", ")} without asking"

          why =
            cond do
              scope == "user" and ask.layer == "project" ->
                "Saving into your agents #{runs} in every workspace, trusted or not: in this " <>
                  "repository's layer that waits until the workspace is trusted."

              scope == "user" ->
                "Saving into your agents #{runs} in every workspace, trusted or not."

              true ->
                "Saving into this repository #{runs} once this workspace is trusted."
            end

          ["", why, "", "y saves it so · any other key goes back"]
      end

    Enum.join(
      ["Save #{ask.name}", "", field("may", permission_words(ask.permissions))] ++
        may ++ warnings ++ choice,
      "\n"
    )
  end

  defp delete_text(ask) do
    Enum.join(
      [
        "Delete #{ask.name} from #{layer_place(ask.scope)}?",
        "",
        field("file", ask.path || "?"),
        "",
        "y deletes it · any other key keeps it"
      ],
      "\n"
    )
  end

  @doc "The command box under the page: the name being typed, or the keys."
  @spec command_line(page()) :: {term(), String.t()}
  def command_line(%{ask: %{kind: :name, text: text, from: from}}),
    do:
      {{:edit, {text, String.length(text)}},
       " new agent from #{from} — its name, then Enter opens your editor on a copy · Esc back "}

  def command_line(%{ask: %{kind: :name, text: text}}),
    do:
      {{:edit, {text, String.length(text)}},
       " new agent — its name, then Enter opens your editor · Esc back "}

  def command_line(%{ask: %{kind: :save, confirm: scope}}) when is_binary(scope),
    do: {"", " save — y saves it · any other key goes back "}

  def command_line(%{ask: %{kind: :save}}),
    do: {"", " save — r this repository · m mine · Enter where it is · Esc keeps your edit "}

  def command_line(%{ask: %{kind: :delete}}),
    do: {"", " delete — y deletes it · any other key keeps it "}

  def command_line(%{view: %{}}),
    do: {"", " instruction — ↑↓ PgUp/PgDn scroll · e edits it · Esc back to the list "}

  def command_line(%{read_only: reason}) when is_binary(reason),
    do: {"", " agents — ↑↓ move · Enter reads it whole · r reload · Esc back · read-only here "}

  def command_line(_page),
    do:
      {"",
       " agents — ↑↓ move · Enter reads it whole · e edit · c copy · n new · x delete · r reload · Esc back "}
end
