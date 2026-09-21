# Two Mix projects live in this repository — the umbrella and `clients/tui` — and each has
# its own `mix.lock`. The TUI builds the harness from the umbrella's own source, so a
# package both of them lock is one the harness runs with twice: once in a pod, locked by
# the umbrella, and once in a laptop's `troupe`, locked by the TUI. Those have to be the
# same version, or the TUI tests a harness nobody deploys.
#
#     elixir scripts/locks-agree.exs
#
# Exits non-zero naming every shared package whose locked version differs. Packages only
# one side locks are that side's business and are not reported.

# Read the way `Mix.Dep.Lock` reads it, warnings off: a lock's keys are quoted strings.
read = fn path ->
  opts = [file: path, emit_warnings: false]
  {:ok, quoted} = path |> File.read!() |> Code.string_to_quoted(opts)
  {lock, _binding} = Code.eval_quoted(quoted, [], opts)
  lock
end

# `{:hex, name, version, …}` or `{:git, url, sha, …}`: the third element is what pins it.
pin = fn entry -> elem(entry, 2) end

umbrella = read.("mix.lock")
tui = read.("clients/tui/mix.lock")

shared = umbrella |> Map.keys() |> Enum.filter(&Map.has_key?(tui, &1)) |> Enum.sort()
differing = Enum.reject(shared, &(pin.(umbrella[&1]) == pin.(tui[&1])))

case differing do
  [] ->
    IO.puts("locks agree: #{length(shared)} shared packages at the same version")

  _ ->
    for name <- differing do
      IO.puts(:stderr, "#{name}: #{pin.(umbrella[name])} in mix.lock, #{pin.(tui[name])} in clients/tui/mix.lock")
    end

    IO.puts(:stderr, "#{length(differing)} shared package(s) locked at different versions")
    System.halt(1)
end
