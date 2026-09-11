defmodule Troupe.Memory do
  @moduledoc """
  The project brief: `.troupe/memory.md`, a YAML frontmatter block plus ordered
  `## ` sections, rendered into every agent's system prompt.

  Pure. `Troupe.Session.Memory` owns the file and is the only writer; nothing
  here touches disk. The brief is durable but never authoritative: it is not an
  event, replay ignores it, and `list_files`/`grep`/`read_file` remain the truth
  about current contents (the same posture `Troupe.Workspace.Survey` takes).

  Parsing is lossless. Sections keep their order, headings nobody recognises are
  preserved, and text before the first heading round-trips as a titleless
  section, so hand edits survive a librarian refresh.
  """

  alias Troupe.Frontmatter

  @type section :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          built_at: DateTime.t() | nil,
          head: String.t() | nil,
          files: non_neg_integer() | nil,
          sections: [section()]
        }

  defstruct built_at: nil, head: nil, files: nil, sections: []

  @canonical ~w(Overview Layout Commands Conventions Notes)
  @notes "Notes"
  @max_notes 40
  @max_chars 6_000
  @max_age_days 7
  # The tracked-file count must drift by both this fraction and this many files
  # before the brief is called stale.
  @drift 0.10
  @min_drift 10

  @preamble """
  What earlier agents in this repository already worked out, so that you do not
  have to. Start from it and treat it as correct: do not survey the layout,
  re-derive the build or test commands, or spend a subagent discovering anything
  it already tells you. Go straight to the files it points you at.

  It describes the shape of the project, not its exact current contents, so
  check an individual fact with `read_file` or `grep` when you are about to
  change the thing it describes, or when what you see contradicts it. That is a
  targeted check, not a reason to explore the repository again.
  """

  @doc "An empty brief. Sections are added as they are written."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "The canonical section titles, in the order the librarian writes them."
  @spec canonical_titles() :: [String.t()]
  def canonical_titles, do: @canonical

  ## Parse and render

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    case Frontmatter.split(content) do
      {:ok, meta, body} ->
        {:ok,
         %__MODULE__{
           built_at: parse_ts(Map.get(meta, "built_at")),
           head: maybe_string(Map.get(meta, "head")),
           files: parse_int(Map.get(meta, "files")),
           sections: sections(body)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = m) do
    frontmatter(m) <> body(m.sections) <> "\n"
  end

  @doc """
  The `# Project brief` block for the system prompt, or `""` when there is
  nothing to say. `:max_chars` caps it (default #{@max_chars}).
  """
  @spec to_prompt(t() | nil, keyword()) :: String.t()
  def to_prompt(brief, opts \\ [])
  def to_prompt(nil, _opts), do: ""
  def to_prompt(%__MODULE__{sections: []}, _opts), do: ""

  def to_prompt(%__MODULE__{} = m, opts) do
    text = m.sections |> body() |> truncate(Keyword.get(opts, :max_chars, @max_chars))
    "\n\n# Project brief\n#{@preamble}\n\n" <> text
  end

  ## Mutation

  @doc "Replaces the named section, or appends it when it is not there yet."
  @spec put_section(t(), String.t(), String.t()) :: t()
  def put_section(%__MODULE__{} = m, title, text) do
    title = canonical(title)
    text = String.trim(text)

    if Enum.any?(m.sections, &titled?(&1, title)) do
      %__MODULE__{m | sections: Enum.map(m.sections, &replace_if(&1, title, text))}
    else
      %__MODULE__{m | sections: m.sections ++ [{title, text}]}
    end
  end

  @doc "Prepends a dated note, dropping an older note with the same text."
  @spec add_note(t(), String.t(), String.t()) :: t()
  def add_note(%__MODULE__{} = m, agent_path, text) do
    text = squish(text)
    line = "- #{Date.utc_today()} #{agent_path}: #{text}"

    notes =
      m
      |> section(@notes)
      |> String.split("\n", trim: true)
      |> Enum.reject(&(note_text(&1) == text))

    put_section(m, @notes, Enum.join(Enum.take([line | notes], @max_notes), "\n"))
  end

  @doc "The named section's body, or `\"\"`."
  @spec section(t(), String.t()) :: String.t()
  def section(%__MODULE__{} = m, title) do
    title = canonical(title)

    case Enum.find(m.sections, &titled?(&1, title)) do
      {_title, text} -> text
      nil -> ""
    end
  end

  @doc "Stamps the build metadata a refresh records."
  @spec stamp(t(), String.t() | nil, non_neg_integer() | nil) :: t()
  def stamp(%__MODULE__{} = m, head, files) do
    %__MODULE__{m | built_at: DateTime.utc_now(), head: head, files: files}
  end

  ## Staleness

  @doc """
  Whether the brief is worth rebuilding. Options: `:max_age_days` (default
  #{@max_age_days}) and `:files`, the tracked-file count now.

  HEAD is recorded for a human to read but deliberately does not trigger a
  refresh: every commit would.
  """
  @spec stale?(t() | nil, keyword()) :: boolean()
  def stale?(brief, opts \\ [])
  def stale?(nil, _opts), do: true
  def stale?(%__MODULE__{built_at: nil}, _opts), do: true
  def stale?(%__MODULE__{sections: []}, _opts), do: true

  def stale?(%__MODULE__{} = m, opts) do
    old?(m.built_at, Keyword.get(opts, :max_age_days, @max_age_days)) or
      drifted?(m.files, Keyword.get(opts, :files))
  end

  defp old?(built_at, max_age_days) do
    DateTime.diff(DateTime.utc_now(), built_at, :second) > max_age_days * 86_400
  end

  defp drifted?(nil, _now), do: false
  defp drifted?(_then, nil), do: false

  # Both a relative and an absolute floor: without the floor a handful of new
  # files makes a small repository's brief permanently stale, and the brief's own
  # first write would invalidate it.
  defp drifted?(then_count, now) do
    delta = abs(now - then_count)
    delta > @min_drift and delta / max(then_count, 1) > @drift
  end

  ## Sections

  defp sections(body) do
    body
    |> String.split("\n")
    |> Enum.reduce([], &collect_line/2)
    |> Enum.map(fn {title, lines} -> {title, lines |> Enum.reverse() |> Enum.join("\n")} end)
    |> Enum.reject(fn {title, text} -> title == "" and String.trim(text) == "" end)
    |> Enum.map(fn {title, text} -> {title, String.trim(text)} end)
    |> Enum.reverse()
  end

  defp collect_line(line, acc) do
    case Regex.run(~r/^##[ \t]+(.+?)[ \t]*$/, line) do
      [_whole, title] -> [{title, []} | acc]
      nil -> append_line(acc, line)
    end
  end

  # Text before the first heading becomes a titleless section, so it round-trips.
  defp append_line([], line), do: [{"", [line]}]
  defp append_line([{title, lines} | rest], line), do: [{title, [line | lines]} | rest]

  defp body(sections), do: Enum.map_join(sections, "\n\n", &render_section/1)

  defp render_section({"", text}), do: text
  defp render_section({title, text}), do: "## #{title}\n#{text}"

  defp titled?({title, _text}, want), do: String.downcase(title) == String.downcase(want)

  defp replace_if({title, text} = section, want, new) do
    if titled?(section, want), do: {title, new}, else: {title, text}
  end

  defp canonical(title) do
    want = title |> to_string() |> String.trim()
    Enum.find(@canonical, want, &(String.downcase(&1) == String.downcase(want)))
  end

  defp note_text(line) do
    case String.split(line, ": ", parts: 2) do
      [_prefix, text] -> text
      [only] -> only
    end
  end

  defp squish(text), do: text |> to_string() |> String.split() |> Enum.join(" ")

  ## Frontmatter

  defp frontmatter(%__MODULE__{built_at: nil, head: nil, files: nil}), do: ""

  defp frontmatter(%__MODULE__{} = m) do
    lines =
      [
        m.built_at && "built_at: #{DateTime.to_iso8601(m.built_at)}",
        m.head && "head: #{m.head}",
        m.files && "files: #{m.files}"
      ]
      |> Enum.reject(&is_nil/1)

    "---\n" <> Enum.join(lines, "\n") <> "\n---\n\n"
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
    end
  end

  defp parse_int(n) when is_integer(n) and n >= 0, do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _rest} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_int(_other), do: nil

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    String.slice(text, 0, max) <> "\n\n(brief truncated)"
  end
end
