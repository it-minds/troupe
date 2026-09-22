# Every relative link in the repository's Markdown names a file that is there.
#
#     elixir scripts/doc-links.exs                  # every Markdown file git knows about
#     elixir scripts/doc-links.exs docs/README.md   # only these
#
# A document that moves leaves its readers' links behind, and nothing else notices: GitHub
# renders a dead link as a link. This reads `[text](target)`, `![alt](target)` and
# `[label]: target` outside code, drops URLs with a scheme and links within the same page,
# and resolves the rest against the linking file's directory (or the repository root, for
# a target starting with `/`, as GitHub does). A target resolves when git knows the file,
# or a file under the directory it names - tracked, or untracked and not ignored - so a
# link to a build output or to a file that is only on this machine does not pass, and the
# comparison is case-sensitive on every operating system, as it is on GitHub.
#
# Only the path is checked. A `#fragment` is not: heading anchors follow the renderer's
# own rules, and a renamed heading breaks a link less badly than a moved file. Nothing here
# touches the network.
#
# Exits non-zero naming every link that does not resolve, as `file:line: target`.

defmodule DocLinks do
  @root Path.expand("..", __DIR__)

  def main(args) do
    known = known_paths()
    files = if args == [], do: markdown_files(), else: Enum.map(args, &relative/1)
    links = for file <- files, {line, target} <- links(file), do: {file, line, target}

    broken =
      Enum.filter(links, fn {file, _line, target} ->
        path = resolve(file, target)
        path != nil and not MapSet.member?(known, path)
      end)

    for {file, line, target} <- broken, do: IO.puts(:stderr, "#{file}:#{line}: #{target}")

    case broken do
      [] ->
        IO.puts("doc links resolve: #{length(links)} links in #{length(files)} files")

      _ ->
        IO.puts(
          :stderr,
          "#{length(broken)} of #{length(links)} links in #{length(files)} files do not resolve"
        )

        System.halt(1)
    end
  end

  # Tracked, plus untracked and not ignored, so a new document is checked before it is added.
  defp git_files(pathspec) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--" | pathspec]

    case System.cmd("git", args, cd: @root) do
      {out, 0} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.uniq()
        |> Enum.filter(&File.regular?(Path.join(@root, &1)))

      {_out, status} ->
        IO.puts(:stderr, "git ls-files exited #{status} in #{@root}; this needs a git checkout")
        System.halt(2)
    end
  end

  defp markdown_files, do: git_files(["*.md"]) |> Enum.sort()

  # Every file, every directory above one, and the root.
  defp known_paths do
    for file <- git_files([]), path <- [file | parents(file)], into: MapSet.new(["."]), do: path
  end

  defp parents(file) do
    case Path.dirname(file) do
      "." -> []
      dir -> [dir | parents(dir)]
    end
  end

  defp relative(arg), do: arg |> Path.expand() |> Path.relative_to(@root)

  # {line, target} for each link outside fenced code and code spans.
  defp links(file) do
    @root
    |> Path.join(file)
    |> File.read!()
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.flat_map_reduce(nil, fn {text, n}, fence ->
      case {fence, Regex.run(~r/^\s*(`{3,}|~{3,})/, text, capture: :all_but_first)} do
        {nil, nil} -> {Enum.map(targets(text), &{n, &1}), nil}
        {nil, [marker]} -> {[], marker}
        {open, [marker]} -> {[], if(closes?(marker, open), do: nil, else: open)}
        {open, nil} -> {[], open}
      end
    end)
    |> elem(0)
  end

  defp closes?(marker, open),
    do: String.first(marker) == String.first(open) and byte_size(marker) >= byte_size(open)

  defp targets(text) do
    text = Regex.replace(~r/(`+).*?\1/, text, "")
    inline = ~r/\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/
    definition = ~r/^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)/

    for [target] <-
          Regex.scan(inline, text, capture: :all_but_first) ++
            Regex.scan(definition, text, capture: :all_but_first),
        do: target |> String.trim_leading("<") |> String.trim_trailing(">")
  end

  # The repository-relative path a target names, or nil when it is not a relative link.
  defp resolve(file, target) do
    path = target |> String.split(["#", "?"], parts: 2) |> hd() |> URI.decode()

    cond do
      path == "" -> nil
      Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/, path) -> nil
      String.starts_with?(path, "/") -> normalise(path)
      true -> file |> Path.dirname() |> Path.join(path) |> normalise()
    end
  end

  # `a/./b/../c/` -> `a/c`. A path that climbs out of the repository keeps its leading
  # `..` and so never matches.
  defp normalise(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [part | acc] when part != ".." -> acc
      part, acc -> [part | acc]
    end)
    |> Enum.reverse()
    |> case do
      [] -> "."
      parts -> Enum.join(parts, "/")
    end
  end
end

DocLinks.main(System.argv())
