defmodule Troupe.Plane.Artifacts.Highlight do
  @moduledoc """
  A Markdown artifact's fenced code, highlighted on the server (#62): comments, strings,
  numbers and the language's keywords as spans (`c`, `s`, `n`, `k`) the document's
  stylesheet colours. A tokenizer, not a parser: what it does not know stays plain text,
  and everything it emits is escaped first.
  """

  alias Troupe.Plane.Artifacts.Markdown

  @keywords %{
    "elixir" =>
      ~w(def defp defmodule defmacro defstruct defimpl defprotocol do end fn case cond with if else unless when in import alias require use quote unquote raise rescue try catch after receive true false nil and or not),
    "js" =>
      ~w(const let var function return if else for while do switch case break continue new class extends import export from default async await try catch finally throw typeof instanceof in of this null undefined true false yield),
    "python" =>
      ~w(def class return if elif else for while in is not and or import from as with try except finally raise lambda pass break continue yield async await None True False global nonlocal),
    "shell" =>
      ~w(if then else elif fi for while do done case esac in function return export local set unset echo exit),
    "rust" =>
      ~w(fn let mut pub struct enum impl trait use mod match if else for while loop return self Self crate super as where async await move ref true false const static unsafe dyn),
    "go" =>
      ~w(func package import var const type struct interface map chan go defer return if else for range switch case default break continue select nil true false),
    "sql" =>
      ~w(select from where insert into values update set delete create table index alter drop join left right inner outer on group by order having limit offset as and or not null is in exists union all distinct primary key references),
    "yaml" => ~w(true false null yes no),
    "json" => ~w(true false null)
  }

  @aliases %{
    "ex" => "elixir",
    "exs" => "elixir",
    "javascript" => "js",
    "ts" => "js",
    "typescript" => "js",
    "tsx" => "js",
    "jsx" => "js",
    "py" => "python",
    "sh" => "shell",
    "bash" => "shell",
    "zsh" => "shell",
    "console" => "shell",
    "rs" => "rust",
    "golang" => "go",
    "yml" => "yaml",
    "postgresql" => "sql"
  }

  @hash_comments ~w(elixir python shell yaml)
  @dash_comments ~w(sql)

  @doc "`code` as escaped HTML, its tokens in spans, for the language `lang` names."
  @spec render(String.t(), String.t()) :: String.t()
  def render(code, lang) do
    language = Map.get(@aliases, lang, lang)

    case Map.fetch(@keywords, language) do
      {:ok, keywords} -> tokens(code, language, MapSet.new(keywords))
      :error -> Markdown.escape(code)
    end
  end

  defp tokens(code, language, keywords) do
    pattern = pattern(language)

    pattern
    |> Regex.split(code, include_captures: true)
    |> Enum.map_join(fn part ->
      cond do
        part == "" ->
          ""

        comment?(part, language) ->
          span("c", part)

        part =~ ~r/\A("|'|`)/ ->
          span("s", part)

        part =~ ~r/\A\d/ ->
          span("n", part)

        MapSet.member?(keywords, if(language == "sql", do: String.downcase(part), else: part)) ->
          span("k", part)

        true ->
          Markdown.escape(part)
      end
    end)
  end

  defp comment?(part, language) do
    String.starts_with?(part, "//") or String.starts_with?(part, "/*") or
      (language in @hash_comments and String.starts_with?(part, "#")) or
      (language in @dash_comments and String.starts_with?(part, "--"))
  end

  defp pattern(language) do
    line_comment =
      cond do
        language in @hash_comments -> "#[^\\n]*"
        language in @dash_comments -> "--[^\\n]*"
        language in ~w(json) -> nil
        true -> "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
      end

    strings =
      ~S{"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'} <>
        if(language == "js", do: ~S{|`(?:\\.|[^`\\])*`}, else: "")

    [line_comment, strings, ~S{\b\d[\d_]*(?:\.\d+)?\b}, ~S{\b[A-Za-z_][A-Za-z0-9_?!]*\b}]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("|")
    |> then(&Regex.compile!("(#{&1})"))
  end

  defp span(class, text), do: "<span class=\"#{class}\">#{Markdown.escape(text)}</span>"
end
