defmodule Mix.Tasks.Troupe.Remote.Smoke do
  @moduledoc """
  Logs in, lists, attaches and sends one input against a real deployment.

  It runs only when `TROUPE_REMOTE_URL` names a plane, and is skipped with a
  message otherwise — the automated suite proves the client against
  `Troupe.FakeRemote` and must never need a deployment.

      TROUPE_REMOTE_URL=https://plane.example mix troupe.remote.smoke

  Environment:

      TROUPE_REMOTE_URL       the plane to talk to (required)
      TROUPE_REMOTE_SESSION   attach to this session instead of creating one
      TROUPE_REMOTE_TEAM      the team to create in (default: the first one)
      TROUPE_REMOTE_PROFILE   the profile to create with (default: the first one)
      TROUPE_REMOTE_PROMPT    what to send (default: a harmless "say hello")
      TROUPE_REMOTE_TIMEOUT   milliseconds to wait for the reply (default 120000)

  A session it creates is left running; the plane's own lifecycle rules decide
  what happens to it, and deleting one is not in the contract.
  """

  use Mix.Task

  alias Troupe.Client
  alias Troupe.Remote.Worker

  @shortdoc "Login, list, attach and one input against a real deployment (skipped without TROUPE_REMOTE_URL)"

  @impl true
  def run(_args) do
    case System.get_env("TROUPE_REMOTE_URL") do
      nil ->
        Mix.shell().info("troupe.remote.smoke: skipped (set TROUPE_REMOTE_URL to run it)")
        :ok

      url ->
        {:ok, _} = Application.ensure_all_started(:troupe)
        smoke(url)
    end
  end

  defp smoke(url) do
    step("discovery and login", fn -> login(url) end)
    origin = step("connect", fn -> connect(url) end)
    me = step("whoami", fn -> whoami(origin) end)
    teams = step("teams", fn -> list_teams(origin, me) end)
    team = System.get_env("TROUPE_REMOTE_TEAM") || List.first(teams)
    profiles = step("profiles.list", fn -> list_profiles(origin, team) end)
    sessions = step("sessions.list", fn -> list_sessions(origin, team) end)

    sid = step("attach", fn -> attach(origin, sessions, team, profiles) end)
    step("input and reply", fn -> input(sid) end)

    Mix.shell().info("\ntroupe.remote.smoke: ok")
  end

  defp login(url) do
    case Troupe.Remote.Credentials.fetch(Troupe.Remote.Discovery.base(url)) do
      {:ok, %{refresh_token: token}} when is_binary(token) ->
        "already signed in"

      _ ->
        0 = Troupe.CLI.Remote.login(url)
        "signed in"
    end
  end

  defp connect(url) do
    {:ok, origin} = Client.connect_plane(url)
    wait(fn -> Client.fleet_status(origin).up? end, 30_000, "the plane did not connect")
    origin
  end

  defp whoami(origin) do
    {:ok, me} = Client.whoami(origin)
    Mix.shell().info("    #{me.name || me.sub} (#{me.sub})")
    me
  end

  defp list_teams(origin, me) do
    {:ok, teams} = Client.teams(origin)
    names = Enum.map(teams, & &1.id)
    Mix.shell().info("    teams: #{Enum.join(names, ", ")} (me: #{me.sub})")
    names
  end

  defp list_profiles(origin, team) do
    {:ok, profiles} = Client.profiles(origin, team)

    for profile <- profiles do
      Mix.shell().info("    #{profile.name} · #{profile.health} · #{capacity(profile.capacity)}")
    end

    profiles
  end

  defp capacity(%{free: free, total: total}) when is_integer(free) and is_integer(total),
    do: "#{free}/#{total} free"

  defp capacity(_capacity), do: "capacity unknown"

  defp list_sessions(origin, team) do
    {:ok, sessions} = Client.sessions(origin, %{team: team})

    for session <- Enum.take(sessions, 10) do
      Mix.shell().info("    #{session.id} · #{session.state} · #{session.title}")
    end

    sessions
  end

  # Attaching to what is already there beats creating something: a smoke test
  # should leave as little behind as it can.
  defp attach(origin, sessions, team, profiles) do
    named = System.get_env("TROUPE_REMOTE_SESSION")

    cond do
      is_binary(named) ->
        {:ok, sid} = Client.open_session(origin, named, :read)
        sid

      session = Enum.find(sessions, &(&1.state == :active)) ->
        {:ok, sid} = Client.open_session(origin, session.id, :read)
        sid

      true ->
        profile = System.get_env("TROUPE_REMOTE_PROFILE") || profile_name(profiles)

        {:ok, sid} =
          Client.create_session(origin, %{
            team: team,
            profile: profile,
            source: %{type: "empty"},
            visibility: "private",
            prompt: prompt()
          })

        sid
    end
    |> tap(fn sid ->
      wait(fn -> Client.capability(sid).up? end, 60_000, "the worker connection never came up")
      Mix.shell().info("    attached to #{sid} on #{Worker.status(sid).endpoint}")
    end)
  end

  defp profile_name([%{name: name} | _]), do: name
  defp profile_name(_profiles), do: "code"

  defp prompt, do: System.get_env("TROUPE_REMOTE_PROMPT") || "say hello and finish"

  defp input(sid) do
    before = length(Client.events(sid))
    :ok = Client.subscribe(sid)

    case Client.send_input(sid, "", prompt()) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("input.send failed: #{inspect(reason)}")
    end

    timeout = System.get_env("TROUPE_REMOTE_TIMEOUT", "120000") |> String.to_integer()

    wait(
      fn -> Enum.count(Client.events(sid)) > before end,
      timeout,
      "no events arrived after the input"
    )

    wait(
      fn -> Enum.any?(Client.events(sid), &(&1.type == :assistant_message)) end,
      timeout,
      "no assistant message arrived"
    )

    "the session answered"
  end

  defp step(name, fun) do
    Mix.shell().info("  #{name}…")
    fun.()
  end

  defp wait(fun, timeout, message) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline, message)
  end

  defp do_wait(fun, deadline, message) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        Mix.raise("troupe.remote.smoke: #{message}")
      else
        Process.sleep(250)
        do_wait(fun, deadline, message)
      end
    end
  end
end
