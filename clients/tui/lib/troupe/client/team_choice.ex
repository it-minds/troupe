defmodule Troupe.Client.TeamChoice do
  @moduledoc """
  The team this machine's sessions on a profile were last for, by plane and profile: where
  more than one of the person's teams may use a profile, `/new` asks once, remembers the
  answer here, shows it on the sentence and lets it be changed there. A remembered team
  that may no longer use the profile is not offered again (`Troupe.UI.NewSession.chosen_team/3`
  drops it) and the person is asked.

  The client's own file, beside the other things this machine remembers for itself, never
  the plane's: the plane is told the team on each create and keeps no preference.
  """

  @doc "Every team remembered for a plane, by profile."
  @spec for_plane(String.t()) :: %{String.t() => String.t()}
  def for_plane(plane) when is_binary(plane) do
    prefix = plane <> "|"

    for {key, team} <- read(),
        String.starts_with?(key, prefix),
        is_binary(team),
        into: %{},
        do: {String.replace_prefix(key, prefix, ""), team}
  end

  def for_plane(_plane), do: %{}

  @doc "Remember the team a profile's sessions on a plane are for."
  @spec remember(String.t(), String.t(), String.t()) :: :ok
  def remember(plane, profile, team)
      when is_binary(plane) and is_binary(profile) and is_binary(team) do
    held = read()
    key = plane <> "|" <> profile

    if held[key] != team do
      path = path()
      _ = File.mkdir_p(Path.dirname(path))
      _ = File.write(path, Jason.encode!(Map.put(held, key, team)))
    end

    :ok
  end

  def remember(_plane, _profile, _team), do: :ok

  defp read do
    with {:ok, text} <- File.read(path()),
         {:ok, %{} = held} <- Jason.decode(text) do
      held
    else
      _none -> %{}
    end
  end

  defp path, do: Path.join(Troupe.Paths.state_dir(), "new-session-teams.json")
end
