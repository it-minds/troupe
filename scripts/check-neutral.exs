# No file in this repository names one deployment of Troupe: not its cloud, its cluster,
# its domain, its registry, its identity tenant or the account it deploys as.
#
#     elixir scripts/check-neutral.exs                  # every file git knows about
#     elixir scripts/check-neutral.exs --digest NAME    # the line to add for NAME
#
# This repository is the product: the chart, the images, the clients and how to build
# them. The deployment its maintainers run lives in a repository of its own and consumes
# the published chart and images as anybody else's would (Decision 734). One of its names
# in a file here tells an adopter nothing they can use, and leaves them guessing which
# parts of an example were somebody's own; an example says `example.com` or
# `example.test`, and says the value is a placeholder.
#
# The names are kept below as SHA-256 digests of their lowercase spelling, so the file
# that keeps them out does not name them itself. Each line is read as runs of letters,
# digits, dots and hyphens, and a run is checked whole, label by label (split at dots),
# word by word (split at hyphens too), and as each of its dotted suffixes: a host is
# caught under any subdomain, and a word inside a hyphenated name is caught as well.
# Tracked files and untracked ones that are not ignored are read, so a new file is
# checked before it is added; a file with a NUL byte in its first 8000 is binary, as git
# decides, and skipped.
#
# A file that has to keep such a name for now is in @allowed, with the reason and what
# ends it. An allowed file that no longer names anything is an error too, so the list
# only shrinks.
#
# Exits non-zero naming every line that names one, as `file:line: run (what it is)`.

defmodule CheckNeutral do
  @root Path.expand("..", __DIR__)

  # digest => what kind of name it is, which is all a failure says about it.
  @names %{
    "acbe5993eb7b17150ad36921576f66801c9115cefaf242d0525217db110ca9b5" => "a cloud provider",
    "8fffc5cf0a53f99d9e9495295382dd4ccdc2dfc73ec3d4d5a3aed3abe012ab3e" =>
      "the provider's Kubernetes",
    "7c8a8e47f2f0f038a0c150d1036546048ae726a1c3e737180703e1bc75746a07" =>
      "the provider's short name",
    "a0139afdee5c87449b0aee99bfdeb881fec6f786525f1ce1a9adac730dad7496" => "the provider's region",
    "95c0859664f18b7e03dc8c5b8c1aceec3a375c5eb964f23b827a001e2753a4c5" => "a deployment's domain",
    "1cb1c1cf79fef527373699f13dd20bc127e08d835164e9d35d6c26ae69c9ac10" => "a deployment's domain",
    "6bed12e3ecb2515182a2b2162e1aa08a6fa095b1582820706bd62de8084e7126" => "a deployment's domain",
    "30ae87ced51777f291aece7af00687e4f4c51359a35a5ef4e69eed17413c36c7" =>
      "a deployment's deploy account",
    "9e55e56522447350552139ef6653ed0c595395f639a9e7499a3e275411ca901b" =>
      "a deployment's identity tenant",
    "818259bb49d98b6132d7ca567cf74b3b724a467893aa88fc27ae65e6975e76e3" =>
      "a deployment's app registration",
    "9cc8463c8a1d79370d14fc2cebc61099d45d5b2fbd8bb2696994b65aaeb6f53b" =>
      "a deployment's app registration"
  }

  # path => why it keeps a name for now, and what ends that. Empty, and best left so.
  @allowed %{}

  def main(["--digest", name]) do
    IO.puts(~s|    "#{digest(String.downcase(name))}" => "<what it is>",|)
  end

  def main([]) do
    files = git_files()
    {found, _cache} = Enum.flat_map_reduce(files, %{}, &check_file/2)

    {allowed, refused} =
      Enum.split_with(found, fn {file, _, _, _} -> Map.has_key?(@allowed, file) end)

    named = allowed |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    stale = @allowed |> Map.keys() |> Enum.reject(&MapSet.member?(named, &1)) |> Enum.sort()

    for {file, line, run, what} <- refused,
        do: IO.puts(:stderr, "#{file}:#{line}: #{run} (#{what})")

    for file <- stale,
        do:
          IO.puts(:stderr, "#{file}: allowed in scripts/check-neutral.exs, and names nothing now")

    cond do
      refused != [] ->
        lines = refused |> Enum.map(fn {file, line, _, _} -> {file, line} end) |> Enum.uniq()
        files = lines |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        IO.puts(:stderr, """

        #{length(lines)} line(s) in #{length(files)} file(s) name one deployment of Troupe, not Troupe.

        This repository is the product. A deployment's own cloud, cluster, domain,
        registry, identity tenant or deploy account belongs in that deployment's own
        repository; in an example here it is a placeholder (example.com, example.test)
        that says it is one. A file that must keep such a name for now goes in @allowed
        in scripts/check-neutral.exs, with the reason and what ends it.
        """)

        System.halt(1)

      stale != [] ->
        IO.puts(:stderr, "\nTake those out of @allowed: the list only shrinks.")
        System.halt(1)

      true ->
        IO.puts("check-neutral: #{length(files) - map_size(@allowed)} files name no deployment")

        for {file, why} <- Enum.sort(@allowed),
            do: IO.puts("check-neutral: allowed for now: #{file} (#{why})")
    end
  end

  def main(_args) do
    IO.puts(:stderr, "usage: elixir scripts/check-neutral.exs [--digest NAME]")
    System.halt(2)
  end

  # [{file, line, run, what}] for one file, and the cache of runs already judged.
  defp check_file(file, cache) do
    text = File.read!(Path.join(@root, file))

    if binary?(text) do
      {[], cache}
    else
      {hits, cache} =
        text
        |> runs()
        |> Enum.uniq()
        |> Enum.flat_map_reduce(cache, fn run, cache ->
          what = Map.get_lazy(cache, run, fn -> judge(run) end)
          {if(what, do: [run], else: []), Map.put(cache, run, what)}
        end)

      case hits do
        [] -> {[], cache}
        hits -> {lines(file, text, MapSet.new(hits), cache), cache}
      end
    end
  end

  defp lines(file, text, hits, cache) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      for run <- Enum.uniq(runs(line)), MapSet.member?(hits, run), do: {file, n, run, cache[run]}
    end)
  end

  defp binary?(text),
    do: :binary.match(binary_part(text, 0, min(byte_size(text), 8000)), <<0>>) != :nomatch

  defp runs(text) do
    for [run] <- Regex.scan(~r/[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?/i, text), do: String.downcase(run)
  end

  # What the run names, or nil.
  defp judge(run) do
    labels = String.split(run, ".")
    words = Enum.flat_map(labels, &String.split(&1, "-"))
    suffixes = for n <- 2..length(labels)//1, do: labels |> Enum.take(-n) |> Enum.join(".")

    Enum.find_value(Enum.uniq(words ++ labels ++ suffixes), &Map.get(@names, digest(&1)))
  end

  defp digest(name), do: :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)

  defp git_files do
    args = ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]

    case System.cmd("git", args, cd: @root) do
      {out, 0} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.uniq()
        |> Enum.filter(&regular?/1)
        |> Enum.sort()

      {_out, status} ->
        IO.puts(:stderr, "git ls-files exited #{status} in #{@root}; this needs a git checkout")
        System.halt(2)
    end
  end

  # Not a symlink, which git lists as a file and which may point anywhere.
  defp regular?(file) do
    case File.lstat(Path.join(@root, file)) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end
end

CheckNeutral.main(System.argv())
