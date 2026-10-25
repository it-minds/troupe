defmodule Troupe.CLI.ModelConfig do
  @moduledoc """
  `troupe config pull [PLANE_URL]`: fetch the organisation's document from a plane now,
  for this machine's organisation layer (root Decision 869).

  The plane answers `me.client_defaults`: its defaults (provider, URL, auth style,
  models; never a key) and what it enforces. This command hands that answer to the
  daemon's `config.organisation`, which keeps it as the copy every later session reads,
  below the person's own file and, for what is enforced, above everything. Nothing is
  written into the person's own `config.yaml`: a copy there would outrank the
  organisation's defaults and never be updated again. The daemon fetches the same
  document itself whenever a client signed in to the plane connects; this is the way to
  have it now.

  The organisation's memory documents come with it (`me.memory`, root issue #55): the
  organisation's and the person's teams', which every session here reads first. The answer
  goes to the daemon's `config.memory` as the plane signed it, and the sessions running
  now read it from their next turn.
  """

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol
  alias Troupe.Remote.Credentials

  @doc """
  Fetch a plane's document into this machine's organisation layer, and the organisation's
  memory documents beside it (root issue #55); returns the exit status.
  """
  @spec pull(String.t() | nil, (String.t() -> any())) :: non_neg_integer()
  def pull(plane_url, say \\ &IO.puts/1) do
    with {:ok, url} <- plane(plane_url),
         {:ok, origin} <- Client.connect_plane(url),
         {:ok, answer} <- Client.client_defaults(origin) do
      settings = keep(url, answer, say)

      memory =
        case Client.memory(origin) do
          {:ok, memory} ->
            keep_memory(url, memory, say)

          # A plane from before memory has none to give.
          {:error, :unsupported} ->
            0

          {:error, reason} ->
            say.("could not pull the organisation's memory: " <> describe(reason))
            1
        end

      max(settings, memory)
    else
      {:error, reason} ->
        say.("could not pull the organisation's settings: " <> describe(reason))
        1
    end
  end

  @doc """
  Hand a plane's `me.memory` answer to the daemon to keep (`config.memory`), signature and
  all: the daemon checks it against the key this machine pinned, keeps it as the copy
  every session here reads first, and gives it to the sessions running now for their next
  turn. Says which documents this machine now reads. Returns the exit status.
  """
  @spec keep_memory(String.t(), map(), (String.t() -> any()), (String.t(), map() ->
                                                                 {:ok, map()} | {:error, term()})) ::
          non_neg_integer()
  def keep_memory(url, answer, say, call \\ &Link.call/2) do
    case call.("config.memory", %{
           "command_id" => Protocol.command_id(),
           "plane_url" => url,
           "document" => answer
         }) do
      {:ok, kept} ->
        report_memory(kept, say)
        0

      {:error, reason} ->
        say.("could not keep the organisation's memory: " <> describe(reason))
        1
    end
  end

  defp report_memory(%{"documents" => []} = kept, say),
    do: say.("#{kept["plane_url"]} has no memory documents for this machine's sessions")

  defp report_memory(kept, say) do
    say.("#{kept["plane_url"]}'s memory for this machine's sessions, kept in #{kept["path"]}:")
    Enum.each(kept["documents"] || [], &say.("  #{memory_label(&1)}, version #{&1["version"]}"))

    if (kept["changed"] || []) != [],
      do: say.("the sessions running here read it from their next turn")
  end

  defp memory_label(%{"scope" => "organisation"}), do: "the organisation's memory"
  defp memory_label(%{"scope" => "user"}), do: "your own memory"
  defp memory_label(%{"scope" => scope, "name" => name}), do: "the #{scope} #{name}'s memory"

  @doc """
  Hand a plane's answer to the daemon to keep, through `call` (the daemon's, by default),
  and say what this machine now takes from the organisation. Returns the exit status.
  """
  @spec keep(String.t(), map(), (String.t() -> any()), (String.t(), map() ->
                                                          {:ok, map()} | {:error, term()})) ::
          non_neg_integer()
  def keep(url, answer, say, call \\ &Link.call/2) do
    case call.("config.organisation", %{
           "command_id" => Protocol.command_id(),
           "plane_url" => url,
           "document" => answer
         }) do
      {:ok, kept} ->
        report(kept, say)
        0

      {:error, reason} ->
        say.("could not keep the organisation's settings: " <> describe(reason))
        1
    end
  end

  defp report(kept, say) do
    defaults = kept["defaults"] || %{}
    enforced = kept["enforced"] || %{}

    if defaults == %{} and enforced == %{} do
      say.(
        "#{kept["plane_url"]} sets no defaults or limits for people's own machines; an administrator sets them " <>
          "on the console's Govern → Policy and settings, in the panel What people's own machines talk to"
      )
    else
      say.("#{kept["plane_url"]}'s settings for this machine, kept in #{kept["path"]}:")

      Enum.each(flatten(defaults), fn {key, value} ->
        say.("  default   #{key} = #{shown(value)}")
      end)

      Enum.each(flatten(enforced), fn {key, value} ->
        say.("  enforced  #{key} = #{shown(value)}")
      end)
    end

    for warning <- kept["warnings"] || [], do: say.("note: #{warning}")

    case kept["shadowed"] || [] do
      [] ->
        :ok

      keys ->
        say.("")

        say.(
          "your own settings set #{Enum.join(keys, ", ")} too, and win over the organisation's defaults; " <>
            "`troupe config --explain KEY` shows where"
        )
    end
  end

  defp flatten(map, prefix \\ []) do
    map
    |> Enum.sort()
    |> Enum.flat_map(fn
      {key, value} when is_map(value) -> flatten(value, prefix ++ [key])
      {key, value} -> [{Enum.join(prefix ++ [key], "."), value}]
    end)
  end

  defp shown(true), do: "on"
  defp shown(false), do: "off"
  defp shown(value), do: to_string(value)

  defp plane(url) when is_binary(url) and url != "", do: {:ok, url}

  defp plane(_none) do
    case Credentials.fetch() do
      {:ok, %{plane_url: url}} -> {:ok, url}
      :error -> {:error, :logged_out}
    end
  end

  defp describe(:logged_out), do: "not signed in; run troupe login <plane-url>"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{data: %{"reason" => reason}}) when is_binary(reason), do: reason
  defp describe(%{data: %{reason: reason}}) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
