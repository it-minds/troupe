defmodule Troupe.Watch.Marker do
  @moduledoc """
  Finding AI comments in source files.

  A marker is a comment whose text starts or ends with the word `AI`, case
  insensitive, in any of the usual comment syntaxes. The suffix decides what it
  means:

    * `AI!` — do this now
    * `AI?` — answer this, without editing anything
    * bare `AI` — context, collected and sent along with the next trigger

  Matching is deliberately conservative about what counts as a comment: a string
  literal containing `# ... AI!` should not launch an agent, so the scan requires the
  comment marker to be the first non-whitespace thing on the line, or to follow code
  with no quote character between it and the start of the line.
  """

  @enforce_keys [:file, :line, :kind, :comment]
  defstruct [:file, :line, :kind, :comment, :context]

  @type kind :: :change | :question | :context
  @type t :: %__MODULE__{
          file: String.t(),
          line: pos_integer(),
          kind: kind(),
          comment: String.t(),
          context: String.t() | nil
        }

  # Ordered longest-first so `//` is not read as two `/` and `<!--` wins over `<`.
  @line_comments ["<!--", "/*", "//", "--", "#", ";", "%"]
  @closers %{"<!--" => "-->", "/*" => "*/"}

  @context_lines 6

  @doc """
  Every marker in a file's contents, with surrounding code attached.

  `path` is what the model will see, so callers pass the workspace-relative path.
  """
  @spec scan(String.t(), String.t()) :: [t()]
  def scan(path, contents) do
    lines = String.split(contents, ~r/\r?\n/)

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      case marker_in_line(line) do
        nil ->
          []

        {kind, comment} ->
          [
            %__MODULE__{
              file: path,
              line: number,
              kind: kind,
              comment: comment,
              context: surrounding(lines, number)
            }
          ]
      end
    end)
  end

  @doc "Whether a line holds a marker, and of which kind. Public for tests."
  @spec marker_in_line(String.t()) :: {kind(), String.t()} | nil
  def marker_in_line(line) do
    case comment_text(line) do
      {:ok, comment} -> classify(comment)
      :error -> nil
    end
  end

  defp comment_text(line) do
    Enum.reduce_while(@line_comments, :error, fn opener, acc ->
      case find_opener(line, opener) do
        nil -> {:cont, acc}
        rest -> {:halt, {:ok, strip_closer(rest, opener)}}
      end
    end)
  end

  # The opener must not sit inside a string literal. Counting quote characters before
  # it is crude but right for the cases that matter, and it fails closed: an odd
  # number of quotes means "probably inside a string", so no marker.
  defp find_opener(line, opener) do
    case :binary.match(line, opener) do
      :nomatch ->
        nil

      {pos, len} ->
        before = binary_part(line, 0, pos)

        if quoted?(before) do
          nil
        else
          binary_part(line, pos + len, byte_size(line) - pos - len)
        end
    end
  end

  defp quoted?(before) do
    Enum.any?([?", ?'], fn quote_char ->
      before |> :binary.matches(<<quote_char>>) |> length() |> rem(2) == 1
    end)
  end

  defp strip_closer(rest, opener) do
    case Map.fetch(@closers, opener) do
      {:ok, closer} ->
        case :binary.match(rest, closer) do
          :nomatch -> rest
          {pos, _} -> binary_part(rest, 0, pos)
        end

      :error ->
        rest
    end
  end

  @leading ~r/\A\s*ai([!?])?(?![\w-])\s*/i
  @trailing ~r/(?<![\w-])ai([!?])?\s*\z/i

  defp classify(comment) do
    trimmed = String.trim(comment)

    cond do
      trimmed == "" ->
        nil

      match = Regex.run(@leading, trimmed) ->
        kind = kind_of(Enum.at(match, 1))
        {kind, trimmed |> String.replace(@leading, "") |> String.trim()}

      match = Regex.run(@trailing, trimmed) ->
        kind = kind_of(Enum.at(match, 1))
        {kind, trimmed |> String.replace(@trailing, "") |> String.trim()}

      true ->
        nil
    end
  end

  defp kind_of("!"), do: :change
  defp kind_of("?"), do: :question
  defp kind_of(_), do: :context

  defp surrounding(lines, number) do
    first = max(number - @context_lines, 1)
    last = min(number + @context_lines, length(lines))

    lines
    |> Enum.slice((first - 1)..(last - 1))
    |> Enum.with_index(first)
    |> Enum.map_join("\n", fn {line, n} -> "#{n}\t#{line}" end)
  end
end
