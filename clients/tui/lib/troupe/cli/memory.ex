defmodule Troupe.CLI.Memory do
  @moduledoc """
  `troupe memory [--edit | --clear | --status]`: the person's own memory on the plane (root
  issue #55, the user level), which every session of theirs reads on every machine, after
  their organisation's memory and before the repository's files. An agent of theirs may add an
  entry to it (`remember` with `level: "me"`); only they change or remove what is there.

  Asked of this machine's daemon, which reads and saves it with its own sign-in
  (`me.memory`, `me.memory.put`) and hands the saved version to the sessions running here
  for their next turn. Alone the command prints it; `--edit` opens it in the person's editor
  (`Troupe.Editor`: `VISUAL`, then `EDITOR`) and saves what they leave there, over the
  version they started from, so a save made elsewhere meanwhile is said, not overwritten;
  `--clear` empties it. A daemon that is not signed in says so.

  `--status` is for the person's own debugging (`me.memory.status`): the versions of the
  organisation's levels and their own that this machine holds, whether the plane has the same
  in force, and which each session running here read at its last turn.
  """

  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol

  @type call :: (String.t(), map() -> {:ok, map()} | {:error, term()})

  @doc "Show, edit or clear the person's own memory; returns the exit status."
  @spec run(map(), (String.t() -> any()), call()) :: non_neg_integer()
  def run(args, say \\ &IO.puts/1, call \\ &Link.call/2)

  def run(%{status: true}, say, call), do: status(say, call)

  def run(args, say, call) do
    case call.("me.memory", %{}) do
      {:ok, own} ->
        cond do
          Map.get(args, :clear) -> save(own, "", say, call)
          Map.get(args, :edit) -> edit(own, say, call)
          true -> show(own, say)
        end

      {:error, reason} ->
        say.("could not read your memory: " <> describe(reason))
        1
    end
  end

  defp show(%{"version" => 0} = own, say) do
    say.(
      "you keep no memory on #{own["plane_url"]} yet. `troupe memory --edit` writes it; every " <>
        "session of yours reads it, on every machine, and an agent of yours may add to it when you ask it to remember something"
    )

    0
  end

  defp show(%{"text" => ""} = own, say) do
    say.(
      "your memory on #{own["plane_url"]} is empty (version #{own["version"]}); `troupe memory --edit` writes it"
    )

    0
  end

  defp show(own, say) do
    say.(
      "your memory on #{own["plane_url"]}, version #{own["version"]}, #{own["bytes"]} of " <>
        "#{own["limit"]} bytes#{saved_by(own)}:"
    )

    say.("")
    say.(own["text"])
    0
  end

  defp saved_by(%{"changed_by" => by, "changed_at" => at}) when is_binary(by) and is_binary(at),
    do: ", saved by #{by} at #{at}"

  defp saved_by(%{"changed_by" => by}) when is_binary(by), do: ", saved by #{by}"
  defp saved_by(_own), do: ""

  defp edit(own, say, call) do
    path = Path.join(System.tmp_dir!(), "troupe-memory-#{System.unique_integer([:positive])}.md")
    File.write!(path, own["text"] <> "\n")

    try do
      case Troupe.Editor.edit(path) do
        outcome when outcome in [:ok, {:terminal, :ok}] ->
          text = path |> File.read!() |> String.replace("\r\n", "\n") |> String.trim_trailing()

          if text == own["text"],
            do: unchanged(say),
            else: save(own, text, say, call)

        {_terminal, {:error, why}} ->
          say.("your memory was not edited: " <> why)
          1

        {:error, why} ->
          say.("your memory was not edited: " <> why)
          1
      end
    rescue
      # An editor the system cannot start as a program, such as an app's alias in
      # WindowsApps, is said as the others are, not as a crash of the command.
      error in ErlangError ->
        say.(
          "your memory was not edited: the editor could not be started (#{Exception.message(error)})"
        )

        1
    after
      File.rm(path)
    end
  end

  defp unchanged(say) do
    say.("your memory is as it was; nothing was saved")
    0
  end

  defp save(%{"text" => "", "version" => _} = _own, "", say, _call), do: unchanged(say)

  defp save(own, text, say, call) do
    params = %{"command_id" => Protocol.command_id(), "text" => text, "version" => own["version"]}

    case call.("me.memory.put", params) do
      {:ok, %{"changed" => false}} ->
        unchanged(say)

      {:ok, %{"user" => now}} ->
        said = if text == "", do: "cleared", else: "saved"

        say.(
          "your memory on #{own["plane_url"]} is #{said}, version #{now["version"]} (#{now["bytes"]} of " <>
            "#{now["limit"]} bytes); the sessions running here read it from their next turn, and " <>
            "your other machines' within five minutes"
        )

        0

      {:error, reason} ->
        say.("your memory was not saved: " <> describe(reason))
        1
    end
  end

  # `--status`: which versions this machine's daemon holds, against what the plane has in
  # force now, and what each session running here read at its last turn. For the person's
  # own debugging; nothing is changed but the copy, which is fetched as at any poll.
  defp status(say, call) do
    case call.("me.memory.status", %{}) do
      {:ok, status} ->
        say.(held_line(status))
        Enum.each(status["documents"] || [], &say.("  " <> document_line(&1)))
        say.(standing_line(status))
        Enum.each(status["sessions"] || [], &say.("  " <> session_line(&1)))
        0

      {:error, reason} ->
        say.("could not ask this machine's daemon: " <> describe(reason))
        1
    end
  end

  defp held_line(%{"problem" => problem}) when is_binary(problem),
    do: "this machine's copy of the plane's memory is not used: #{problem}"

  defp held_line(%{"documents" => [], "fetched_at" => nil}),
    do: "this machine holds no copy of the plane's memory"

  defp held_line(status),
    do:
      "this machine holds the memory of #{status["plane_url"]}, fetched #{status["fetched_at"]}, kept in #{status["path"]}:"

  defp document_line(document),
    do: "#{label(document)}, version #{document["version"]} (#{short(document["hash"])})"

  defp label(%{"scope" => "organisation"}), do: "the organisation's memory"
  defp label(%{"scope" => "team", "name" => name}), do: "the team #{name}'s memory"
  defp label(%{"scope" => "profile", "name" => name}), do: "the worker profile #{name}'s memory"
  defp label(%{"scope" => "user"}), do: "your own memory"
  defp label(%{"scope" => scope}), do: "#{scope} memory"

  defp short("sha256:" <> hex), do: "sha256:" <> String.slice(hex, 0, 12)
  defp short(other), do: to_string(other)

  defp standing_line(%{"current" => true}), do: "current: the plane has the same versions in force"

  defp standing_line(%{"current" => false, "in_force" => in_force}),
    do:
      "behind: the plane has " <>
        Enum.map_join(in_force, "; ", &document_line/1) <> " in force, now fetched"

  defp standing_line(%{"reason" => reason}), do: "not checked against the plane: #{reason}"

  defp session_line(%{"session_id" => id, "turn_at" => at, "current" => current} = session) do
    read =
      session["documents"]
      |> List.wrap()
      |> Enum.map_join(", ", &"#{&1["scope"]} v#{&1["version"]}")

    word = if current, do: "current", else: "behind until its next turn"
    "session #{id}, last turn #{at}: #{if read == "", do: "no memory", else: read} (#{word})"
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{data: %{"reason" => reason}}) when is_binary(reason), do: reason
  defp describe(%{data: %{reason: reason}}) when is_binary(reason), do: reason
  defp describe(%{"data" => %{"reason" => reason}}) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
