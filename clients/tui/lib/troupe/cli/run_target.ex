defmodule Troupe.CLI.RunTarget do
  @moduledoc """
  Where `troupe run` puts its task, and what it sends: this computer's daemon, or the
  platform as `/new`'s screen would start it.

  The task text reads the same inline tokens as the new-session screens
  (`Troupe.UI.NewSession`): `@profile`, `#agent`, `/local` and `/platform`, each only
  where it names something on offer, taken out before the agent reads the task. A flag is
  the chip and a token in the task wins over it: `--profile dev` with `@ops` in the task
  runs on ops, `plan` as the AGENT word with `#build` runs build. `--profile`, or a
  `@profile` token without `/local`, puts the run on the platform; `/platform` alone does
  too, on the profile the screen would pick (the last used with room, else the first with
  room). The title is `--title`, else the task's first line.

  A full profile makes the run wait for the next free place, as the plane makes every
  create on it wait; the wait is printed one line at a time, as the plane says when to ask
  again. At the administrator's ceiling the plane refuses, and the run fails with its
  sentence.
  """

  alias Troupe.CLI
  alias Troupe.Client
  alias Troupe.Client.{Profiles, Remote}
  alias Troupe.UI.NewSession

  @doc "The origin to create on and the params to create with, or why not."
  @spec resolve(CLI.args(), IO.device()) :: {Client.origin(), map()} | {:error, String.t()}
  def resolve(args, io \\ :stdio) do
    task = args.task || ""
    plane = plane_for(args, task)
    rows = profile_rows(plane)
    names = %{profiles: Enum.map(rows, & &1["name"]), agents: agent_names(args.workspace, rows)}
    tokens = NewSession.tokens(task, names)
    cleaned = NewSession.clean(task, names)
    where = tokens[:where] || if(args.profile || tokens[:profile], do: :platform, else: :local)
    title = args.title || NewSession.title(cleaned)

    case where do
      :local ->
        params = Troupe.CLI.Runner.run_params(%{args | task: cleaned})
        agent = tokens[:agent] || args.agent
        {{:local, args.workspace}, Map.merge(params, %{profile: agent, title: blank(title)})}

      :platform ->
        on_platform(plane, rows, args, tokens, cleaned, title, io)
    end
  end

  defp on_platform({:error, reason}, _rows, _args, _tokens, _cleaned, _title, _io),
    do: {:error, "troupe run on the platform: " <> Profiles.refusal(reason)}

  defp on_platform({:ok, origin}, rows, args, tokens, cleaned, title, io) do
    profile =
      tokens[:profile] || args.profile || elem(NewSession.auto_pick(rows, last_used(origin)), 0)

    cond do
      is_nil(profile) ->
        {:error, "there is no profile you may start a session on"}

      rows != [] and not Enum.any?(rows, &(&1["name"] == profile)) ->
        {:error, Profiles.refusal(:not_found, profile)}

      true ->
        agent = tokens[:agent] || if(args.agent_given, do: args.agent)

        {origin,
         %{
           profile: profile,
           agent: agent,
           title: blank(title),
           prompt: cleaned,
           on_wait: fn answer -> waiting(io, profile, answer) end
         }}
    end
  end

  # One line a wait, in the curtain line's words, with when the plane says to ask again.
  defp waiting(io, profile, answer) do
    ms = answer["retry_after_ms"] || 2_000

    IO.puts(
      io,
      "troupe: waiting for a free place in #{profile}; asking again in #{div(ms + 999, 1000)} s"
    )

    :go_on
  end

  # The plane is asked only where the run may go there: `--profile`, or a task that could
  # name a profile or the platform. Under Local only it is never asked.
  defp plane_for(args, task) do
    if args.profile || String.contains?(task, ["@", "/platform"]),
      do: Profiles.plane(nil),
      else: {:error, :not_asked}
  end

  defp profile_rows({:ok, origin}) do
    case Remote.profile_rows(origin) do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  defp profile_rows(_none), do: []

  # The agents a token may name: this workspace's, as the daemon lists them, and every
  # profile's on the platform.
  defp agent_names(workspace, rows) do
    local =
      case Client.profiles({:local, workspace}) do
        {:ok, agents} -> Enum.map(agents, & &1.name)
        {:error, _reason} -> []
      end

    remote = Enum.flat_map(rows, &List.wrap(&1["agents"]))
    Enum.uniq(local ++ Enum.map(remote, &if(is_map(&1), do: &1["name"], else: to_string(&1))))
  end

  # The profile of the person's newest session on the plane, which the auto-pick starts from.
  defp last_used(origin) do
    case Remote.session_rows(origin) do
      {:ok, rows} ->
        rows
        |> Enum.filter(&is_binary(&1["profile"]))
        |> Enum.max_by(&to_string(&1["last_active_at"]), fn -> %{} end)
        |> Map.get("profile")

      {:error, _reason} ->
        nil
    end
  end

  defp blank(""), do: nil
  defp blank(text), do: text
end
