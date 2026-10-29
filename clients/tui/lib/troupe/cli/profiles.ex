defmodule Troupe.CLI.Profiles do
  @moduledoc """
  `troupe profiles`: what the profiles the person may use give a session, from the command
  line, in the words `/profiles` and `/profile <name>` use.

      troupe profiles [--json]          each profile and its summary
      troupe profiles NAME [--json]     what NAME gives a session: agents, tools, model,
                                        reach, limits and who

  Asked of the plane this machine is signed in to, with the terminal's own sign-in, as
  `troupe whoami` is. `--json` prints the plane's answer as it came (`profile.get`'s, one
  per profile for the list), for a program; the plain lines are the headless printer's
  (`Troupe.UI.Headless.Printer.profile_lines/2`). A profile the person may not use exits 1
  saying so.
  """

  alias Troupe.Client
  alias Troupe.UI.Headless.Printer

  @type say :: (String.t() -> any())

  @doc "What `troupe profiles …` asks, from the words after `profiles`."
  @spec parse([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse(argv) do
    case OptionParser.parse(argv, strict: [json: :boolean]) do
      {opts, [], []} ->
        {:ok, %{name: nil, json: Keyword.get(opts, :json, false)}}

      {opts, [name], []} ->
        {:ok, %{name: name, json: Keyword.get(opts, :json, false)}}

      {_opts, _words, []} ->
        {:error, "usage: troupe profiles [NAME] [--json]"}

      {_opts, _words, invalid} ->
        {:error,
         "unknown option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))} (troupe profiles takes --json)"}
    end
  end

  @doc "Run it; returns the exit status."
  @spec run(map(), say()) :: non_neg_integer()
  def run(asked, say \\ &IO.puts/1)

  def run(%{name: nil} = asked, say) do
    case Client.offered_profiles() do
      {:ok, pages} ->
        if asked.json,
          do: say.(Jason.encode!(Enum.map(pages, &Map.delete(&1, "listed_only")), pretty: true)),
          else: Enum.each(Printer.profiles_lines(pages), say)

        0

      {:error, reason} ->
        refuse(say, Client.profile_refusal(reason))
    end
  end

  def run(%{name: name} = asked, say) do
    case Client.profile_page(name) do
      {:ok, page} ->
        if asked.json,
          do: say.(Jason.encode!(page, pretty: true)),
          else: Enum.each(Printer.profile_lines(page), say)

        0

      {:error, reason} ->
        refuse(say, Client.profile_refusal(reason, name))
    end
  end

  defp refuse(say, reason) do
    say.("troupe profiles: " <> reason)
    1
  end
end
