defmodule Troupe.Client.Profiles do
  @moduledoc """
  What a profile the person may use gives a session of theirs, before they start one:
  `/profiles`, `/profile <name>` and `troupe profiles` ask it here.

  The plane composes the answer (`profile.get`) from what it enforces for this caller —
  the agents the profile and their team's grant leave, the tools and MCP servers with
  whose access each runs, the model, the hosts it reaches, the limits — so the terminal
  says what holds rather than what a bundle file might mean. Nothing here composes a
  profile from its parts: a client that did would say one thing while the plane enforced
  another.

  It is asked of the plane this machine is signed in to, with the terminal's own sign-in,
  as `profiles.list` is for HQ. A listing is `profiles.list` for the names, then
  `profile.get` for each one, so each row's summary is from the same answer its page is;
  a plane from before `profile.get` still lists its profiles, from what `profiles.list`
  says. Under Local only nothing is asked.
  """

  alias Troupe.Client.Remote

  @doc "The plane the person is signed in to, connected; or why there is none."
  @spec plane(Troupe.Client.origin() | nil) :: {:ok, Troupe.Client.origin()} | {:error, term()}
  def plane(origin \\ nil)

  def plane({:remote, _url} = origin),
    do: if(local_only?(), do: {:error, :local_only}, else: {:ok, origin})

  def plane(nil) do
    case {local_only?(), Remote.default_plane()} do
      {true, _plane} -> {:error, :local_only}
      {false, nil} -> {:error, :logged_out}
      {false, {:remote, url}} -> Remote.connect(url)
    end
  end

  def plane(_local), do: plane(nil)

  @doc """
  Every profile the person may use, each as much of `profile.get`'s answer as the plane
  gave: the whole of it where the method answers, else the listing's row with `name`,
  `channel`, `bundle_version`, `limits` and `agents` as names, which the summary reads alike.
  """
  @spec list(Troupe.Client.origin() | nil) :: {:ok, [map()]} | {:error, term()}
  def list(origin \\ nil) do
    with {:ok, plane} <- plane(origin),
         {:ok, rows} <- Remote.profile_rows(plane) do
      {:ok, Enum.map(rows, &page_or_row(plane, &1))}
    end
  end

  defp page_or_row(plane, %{"name" => name} = row) when is_binary(name) do
    case Remote.profile_page(plane, name) do
      {:ok, page} -> page
      {:error, _none} -> from_row(row)
    end
  end

  defp page_or_row(_plane, row), do: from_row(row)

  # A listing's row in the answer's shape, so far as it says: the agents by name, the
  # sessions as the live plane counts them. Anything it does not say stays unsaid.
  defp from_row(row) do
    agents =
      for agent <- List.wrap(row["agents"]) do
        if is_map(agent), do: agent, else: %{"name" => to_string(agent)}
      end

    %{
      "name" => row["name"],
      "channel" => row["channel"],
      "bundle_version" => row["bundle_version"],
      "bundle_hash" => row["bundle_hash"],
      "agents" => agents,
      "limits" => %{
        "capacity" => capacity(row["capacity"]),
        "active_sessions" => row["active_sessions"] || active(row["capacity"])
      },
      "listed_only" => true
    }
  end

  defp capacity(%{"total" => total}), do: total
  defp capacity(total) when is_integer(total), do: total
  defp capacity(_unsaid), do: nil

  defp active(%{"total" => total, "free" => free}) when is_integer(total) and is_integer(free),
    do: total - free

  defp active(_unsaid), do: nil

  @doc "One profile's answer, for the person: `{:error, :not_found}` for one they may not use."
  @spec get(Troupe.Client.origin() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def get(origin \\ nil, name) do
    with {:ok, plane} <- plane(origin), do: Remote.profile_page(plane, name)
  end

  @doc "Why a profile, or the list, could not be shown, in a sentence."
  @spec refusal(term(), String.t() | nil) :: String.t()
  def refusal(reason, name \\ nil)

  def refusal(:not_found, name) when is_binary(name),
    do: "#{name} is not a profile you may use; /profiles and troupe profiles list those you may"

  def refusal(:not_found, _name), do: "no such profile"

  def refusal(:local_only, _name),
    do:
      "Local only: the plane is not asked. Turn local_only off in your user config to see its profiles."

  def refusal(:logged_out, _name),
    do:
      "not signed in to a plane; troupe login <plane-url> signs in, and its profiles are listed here"

  def refusal(:unsupported, _name),
    do: "this plane does not say what a profile gives a session yet; it is from before profile.get"

  def refusal(:plane_down, _name), do: "the plane is unreachable"
  def refusal(:timeout, _name), do: "the plane did not answer in time"
  def refusal(reason, _name) when is_binary(reason), do: reason
  def refusal(reason, _name), do: inspect(reason)

  defp local_only?, do: Troupe.CLI.LocalOnly.on?()
end
