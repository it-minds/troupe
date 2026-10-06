defmodule Troupe.Instructions.Check.Text do
  @moduledoc """
  One instruction file read the way `Troupe.Instructions.Check` looks at it: its code
  spans and links, the commands in its spans and fenced blocks, and its rules (each
  paragraph and list item), every one with the line it starts on (Decision 810).

  What counts is narrow on purpose. A span is a command only when it starts with a
  program from a short list of build tools, a fenced line only in a block marked as a
  shell or in one with no language, and a span is a path only when it reads as one in
  this repository. Anything else is prose, and passed over.

  Pure.
  """

  @typedoc """
  A command a rule names: the text as written, the program `PATH` would have to find,
  the command with its wrappers taken off (`mise exec -- mix test` is `mix test`), and
  whether the program is one to look for.
  """
  @type command :: %{
          line: pos_integer(),
          text: String.t(),
          program: String.t(),
          command: String.t(),
          words: pos_integer(),
          check?: boolean()
        }

  @type t :: %{
          spans: [{pos_integer(), String.t()}],
          links: [{pos_integer(), String.t()}],
          prose: [{pos_integer(), String.t()}],
          commands: [command()],
          rules: [{pos_integer(), String.t()}]
        }

  # The programs a code span may start a command with: build tools, their wrappers and
  # what a repository's rules usually tell an agent to run. A span starting with any
  # other word is not taken for a command.
  @known ~w(npm npx pnpm pnpx yarn bun bunx deno node mix iex elixir erl rebar3 cargo rustc
            rustup go gofmt golangci-lint python python3 pip pip3 pytest tox nox uv uvx
            poetry pipenv pdm hatch ruff black flake8 pylint mypy make cmake bazel mise asdf
            docker podman kubectl helm terraform bundle rake ruby rspec rails gradle mvn
            dotnet java tsc eslint prettier jest vitest playwright git gh zig swift php
            composer)

  # A span of one word is a name more often than a command (`go`, `node`, `black`); these
  # are commands on their own.
  @alone ~w(pytest make)

  # In a shell block every program is looked for but these: the shell's own words and
  # builtins, the tools every shell has, and the platform's package managers, which name
  # how to set a machine up rather than what the repository runs.
  @unchecked ~w(if then else elif fi for while until do done case esac in function select
                time coproc { } [ [[ ! cd pushd popd dirs export unset set source . alias
                unalias echo printf read exit return break continue shift eval exec trap
                wait ulimit umask type command builtin declare typeset local let readonly
                hash history jobs fg bg kill true false test pwd getopts ls cat cp mv rm
                mkdir rmdir touch ln chmod chown grep egrep sed awk find head tail wc sort
                uniq cut tr xargs tee diff patch tar gzip gunzip zip unzip curl wget which
                whereis env sudo su date sleep ps df du less more open start clear man nano
                vi vim code apt apt-get brew choco winget scoop dnf yum pacman apk snap port
                dir cls gci gc gi ii iwr irm ni ri rni sl gl si where call copy del ren md rd
                mklink rem setlocal endlocal goto)

  @shells ~w(sh bash shell zsh fish ksh powershell pwsh ps1 ps cmd bat batch)
  @consoles ~w(console terminal shell-session sh-session)

  # A word a program can be: not a path, a variable, an operator or a placeholder.
  @program ~r/^[A-Za-z0-9_][A-Za-z0-9_.+-]*$/

  # A PowerShell cmdlet, `Verb-Noun`: never on the PATH, always there.
  @cmdlet ~r/^[A-Z][a-z]+-[A-Z][A-Za-z]+$/

  # Any indentation: a fence inside a list item is as much a fence.
  @fence ~r/^\s*(```|~~~)\s*([^\s`]*)/

  @doc "Reads a file's content."
  @spec read(String.t()) :: t()
  def read(content) do
    lines =
      content
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {text, n} -> {n, text} end)
      |> front_matter()

    state = %{fence: nil, block: [], blocks: [], unit: nil, rules: [], prose: []}
    state = lines |> Enum.reduce(state, &step/2) |> flush()

    prose = Enum.reverse(state.prose)
    blocks = Enum.reverse(state.blocks)

    spans = for {n, text} <- prose, span <- spans(text), do: {n, span}

    %{
      spans: spans,
      links: for({n, text} <- prose, link <- links(text), do: {n, link}),
      prose: prose,
      commands: span_commands(spans) ++ Enum.flat_map(blocks, &block_commands/1),
      rules: Enum.reverse(state.rules)
    }
  end

  # A `---` block at the very top is metadata (a `.mdc` rule's globs), not a rule.
  defp front_matter([{1, "---"} | rest]) do
    case Enum.drop_while(rest, fn {_n, text} -> String.trim(text) != "---" end) do
      [_close | body] -> body
      [] -> rest
    end
  end

  defp front_matter(lines), do: lines

  ## Lines

  defp step({n, text}, %{fence: nil} = state) do
    cond do
      match = Regex.run(@fence, text) ->
        [_all, _marker, lang] = match
        %{flush(state) | fence: String.downcase(lang), block: []}

      String.trim(text) == "" ->
        flush(state)

      heading?(text) or table?(text) or rule_line?(text) or html?(text) ->
        state |> flush() |> prose(n, text)

      item = list_item(text) ->
        state |> flush() |> Map.put(:unit, {n, [item]}) |> prose(n, text)

      true ->
        state |> append(n, quote_text(text)) |> prose(n, text)
    end
  end

  defp step({n, text}, %{fence: lang} = state) do
    if Regex.match?(~r/^\s*(```|~~~)/, text),
      do: %{state | fence: nil, blocks: [{lang, Enum.reverse(state.block)} | state.blocks]},
      else: %{state | block: [{n, text} | state.block]}
  end

  # A file that ends inside a fence still has the block it opened.
  defp flush(%{fence: lang, block: block} = state) when is_binary(lang) and block != [],
    do: flush_unit(%{state | blocks: [{lang, Enum.reverse(block)} | state.blocks], block: []})

  defp flush(state), do: flush_unit(state)

  defp flush_unit(%{unit: nil} = state), do: state

  defp flush_unit(%{unit: {n, parts}} = state) do
    text = parts |> Enum.reverse() |> Enum.join(" ") |> normal()
    rules = if rule?(text), do: [{n, text} | state.rules], else: state.rules
    %{state | unit: nil, rules: rules}
  end

  defp append(%{unit: nil} = state, n, text), do: %{state | unit: {n, [text]}}

  defp append(%{unit: {first, parts}} = state, _n, text),
    do: %{state | unit: {first, [text | parts]}}

  defp prose(state, n, text), do: %{state | prose: [{n, text} | state.prose]}

  defp heading?(text), do: text =~ ~r/^\s{0,3}\#{1,6}(\s|$)/
  defp table?(text), do: text =~ ~r/^\s*\|/
  defp rule_line?(text), do: text =~ ~r/^\s{0,3}([-*_])(\s*\1){2,}\s*$/
  defp html?(text), do: text =~ ~r/^\s*</

  defp list_item(text) do
    case Regex.run(~r/^\s*(?:[-*+]|\d+[.)])\s+(.*)$/, text) do
      [_all, rest] -> rest
      nil -> nil
    end
  end

  defp quote_text(text), do: String.replace(text, ~r/^\s*>\s?/, "")

  ## Rules

  # The form two rules are compared in: without the marks that do not change what they
  # say, in one case, with one space.
  defp normal(text) do
    text
    |> String.replace(~r/`+|\*\*|__/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  # A heading-sized line is said again everywhere; a rule has a sentence's words.
  defp rule?(text), do: length(String.split(text)) >= 5

  ## Spans and links

  defp spans(text) do
    for [_all, _ticks, span] <- Regex.scan(~r/(`+)(.+?)\1/, text),
        span = String.trim(span),
        span != "",
        do: span
  end

  # Link targets, with the code spans taken out first, so a link written in one is not.
  defp links(text) do
    text = String.replace(text, ~r/(`+).+?\1/, "")
    inline = Regex.scan(~r/!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/, text)
    reference = Regex.scan(~r/^\s{0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?/, text)
    for [_all, target] <- inline ++ reference, do: target
  end

  ## Commands

  defp span_commands(spans) do
    for {n, span} <- spans,
        segment <- segments(strip_prompt(span)),
        command = command(segment),
        command != nil,
        known?(command),
        do: Map.merge(command, %{line: n, check?: true})
  end

  defp known?(%{program: program, words: words}),
    do: program in @known and (words > 1 or program in @alone)

  # The commands of one fenced block. A shell block's every program is looked for; a block
  # with no language is held to the spans' list; a console's lines count only after a
  # prompt; any other language holds no commands.
  defp block_commands({lang, lines}) do
    case kind(lang) do
      :other ->
        []

      kind ->
        lines |> Enum.reduce({[], :line}, &block_line(&1, &2, kind)) |> elem(0) |> Enum.reverse()
    end
  end

  defp kind(lang) when lang in @shells, do: :shell
  defp kind(lang) when lang in @consoles, do: :console
  defp kind(""), do: :plain
  defp kind(_lang), do: :other

  # A heredoc's body and a line a backslash carried on are not commands of their own.
  defp block_line({_n, text}, {found, {:heredoc, marker}}, _kind),
    do: {found, if(String.trim(text) == marker, do: :line, else: {:heredoc, marker})}

  defp block_line({_n, text}, {found, :continued}, _kind), do: {found, after_line(text)}

  defp block_line({n, text}, {found, :line}, kind) do
    case command_line(text, kind) do
      nil ->
        {found, :line}

      "" ->
        {found, after_line(text)}

      line ->
        commands =
          for segment <- segments(line),
              command = command(segment),
              command != nil,
              kind != :plain or known?(command),
              do: Map.merge(command, %{line: n, check?: checked?(command, kind)})

        {Enum.reverse(commands, found), after_line(text)}
    end
  end

  # A line's command, without its prompt and its comment: in a console, only a line after a
  # prompt has one.
  defp command_line(text, :console),
    do: if(prompted?(text), do: text |> strip_prompt() |> strip_comment())

  defp command_line(text, _kind), do: text |> strip_prompt() |> strip_comment()

  defp after_line(text) do
    cond do
      heredoc = Regex.run(~r/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/, text) ->
        {:heredoc, List.last(heredoc)}

      text =~ ~r/@'\s*$/ ->
        {:heredoc, "'@"}

      text =~ ~r/@"\s*$/ ->
        {:heredoc, "\"@"}

      text =~ ~r/(\\|`)\s*$/ ->
        :continued

      true ->
        :line
    end
  end

  defp checked?(%{program: program}, :plain), do: program in @known

  defp checked?(%{program: program}, _shell),
    do: program not in @unchecked and not Regex.match?(@cmdlet, program)

  defp prompted?(text), do: text =~ ~r/^\s*(\$|%|PS [^>]*>|>)\s+/

  defp strip_prompt(text), do: String.replace(text, ~r/^\s*(\$|%|PS [^>]*>|>)\s+/, "")

  # A `#` that starts a word starts a comment; a whole line of one, or of `::` or `REM`,
  # is nothing.
  defp strip_comment(text) do
    if text =~ ~r/^\s*(#|::|REM\s|rem\s)/,
      do: "",
      else: text |> String.replace(~r/(^|\s)#.*$/, "") |> String.trim()
  end

  defp segments(line), do: line |> String.split(~r/&&|\|\||;|\|/) |> Enum.map(&String.trim/1)

  # The program and the command it runs: assignments, `env` and `sudo` first are not it,
  # and `mise exec --`, `uv run` and their like run what follows them.
  defp command(segment) do
    case drop_preamble(String.split(segment)) do
      [program | _rest] = words ->
        if Regex.match?(@program, program) do
          %{
            text: segment,
            program: program,
            command: words |> unwrap() |> manager_flags() |> Enum.join(" "),
            words: length(words)
          }
        end

      [] ->
        nil
    end
  end

  defp drop_preamble([word | rest]) when word in ["env", "sudo"], do: drop_preamble(rest)

  defp drop_preamble([word | rest] = words) do
    if word =~ ~r/^[A-Za-z_][A-Za-z0-9_]*=/, do: drop_preamble(rest), else: words
  end

  defp drop_preamble([]), do: []

  defp unwrap(["mise", sub | rest]) when sub in ["exec", "x"] do
    case Enum.split_while(rest, &(&1 != "--")) do
      {_tools, ["--" | command]} -> unwrap(command)
      {command, []} -> unwrap(command)
    end
  end

  defp unwrap([tool, "run" | rest]) when tool in ~w(uv poetry pipenv pdm hatch), do: unwrap(rest)
  defp unwrap(["bundle", "exec" | rest]), do: unwrap(rest)
  defp unwrap(words), do: words

  # A package manager's own options before the script (`pnpm -C frontend test`) do not
  # change which script it runs.
  @managers ~w(npm pnpm yarn bun)
  @valued ~w(-C --dir --filter -F --prefix -w --workspace --cwd)

  defp manager_flags([manager | rest]) when manager in @managers,
    do: [manager | drop_flags(rest)]

  defp manager_flags(words), do: words

  defp drop_flags([flag, _value | rest]) when flag in @valued, do: drop_flags(rest)
  defp drop_flags(["-" <> _flag | rest]), do: drop_flags(rest)
  defp drop_flags(words), do: words
end
