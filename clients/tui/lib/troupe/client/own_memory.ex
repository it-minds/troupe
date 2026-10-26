defmodule Troupe.Client.OwnMemory do
  @moduledoc """
  The person's own memory on the plane (root #55's user level), for the terminal's
  `/memory` screen: the calls `troupe memory` makes, through this machine's daemon and its
  sign-in (`me.memory`, `me.memory.put`, `me.memory.status`), so the screen and the command
  line read and save the same document the same way.

  A save names the version it was edited from; one made elsewhere since is a `conflict`,
  answered with the version in force, never an overwrite. Rolling back is saving an old
  version's text over the one in force, a version of its own.
  """

  alias Troupe.CLI.Memory
  alias Troupe.Client.Artifacts
  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol

  @doc """
  The document as the plane has it now: `version` (`0` for none), `text`, `bytes`, `limit`,
  who saved it and `plane_url`, and the levels above it (`documents`); `blame: true` adds `lines`.
  """
  @spec own(keyword()) :: {:ok, map()} | {:error, String.t()}
  def own(opts \\ []) do
    params =
      %{}
      |> then(&if(opts[:blame], do: Map.put(&1, "blame", true), else: &1))

    case Link.call("me.memory", params) do
      {:ok, own} -> {:ok, own}
      {:error, reason} -> {:error, Artifacts.reason(reason)}
    end
  end

  @doc """
  Save `text` over `version`, the one it was edited from: `{:ok, document}` as it now stands
  (`changed: false` where it was the same text), `{:conflict, newest}` where another save
  came first, with the document in force, or the sentence that refused it.
  """
  @spec save(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def save(text, version) do
    params = %{"command_id" => Protocol.command_id(), "text" => text, "version" => version}
    saved(Link.call("me.memory.put", params))
  end

  defp saved(answer) do
    case answer do
      {:ok, %{"user" => now} = saved} ->
        {:ok, Map.put(now, "changed", saved["changed"] != false)}

      {:ok, saved} ->
        {:ok, Map.put(saved, "changed", saved["changed"] != false)}

      {:error, "conflict" <> _} ->
        case own() do
          {:ok, newest} -> {:conflict, newest}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Artifacts.reason(reason)}
    end
  end

  @doc """
  The document's history (`me.memory.history`): every version, newest first, each `{version,
  hash, bytes, changed_by, changed_at}`, and `version`'s text beside `against`'s (`text`,
  `against_text`), the one in force and the one before it where none is named.
  """
  @spec history(keyword()) :: {:ok, map()} | {:error, String.t()}
  def history(opts \\ []) do
    params =
      for {key, value} <- [{"version", opts[:version]}, {"against", opts[:against]}],
          value != nil,
          into: %{},
          do: {key, value}

    case Link.call("me.memory.history", params) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, Artifacts.reason(reason)}
    end
  end

  @doc """
  Roll back to version `to`, over `version`, the one in force as the person saw it: its text
  saved as the next version. Answered as `save/2` is.
  """
  @spec rollback(pos_integer(), non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def rollback(to, version) do
    params = %{"command_id" => Protocol.command_id(), "to" => to, "version" => version}
    saved(Link.call("me.memory.rollback", params))
  end

  @doc """
  Where this machine's copy stands (`me.memory.status`), with the lines `troupe memory
  --status` prints of it, and each document as the copy holds it (`held`), which is all the
  screen shows where the plane is not asked.
  """
  @spec status() :: {:ok, %{lines: [String.t()], held: [map()]}} | {:error, String.t()}
  def status do
    case Link.call("me.memory.status", %{}) do
      {:ok, status} -> {:ok, %{lines: Memory.status_lines(status), held: List.wrap(status["held"])}}
      {:error, reason} -> {:error, Artifacts.reason(reason)}
    end
  end

  @doc "Who wrote a line, as `troupe memory --blame` says it."
  @spec written_by(map()) :: String.t()
  defdelegate written_by(line), to: Memory

  @doc """
  Whether the person has an editor of their own (`VISUAL` or `EDITOR`), which the screen's
  `e` opens; without one it edits in a box of its own, rather than in Notepad or `vi`.
  """
  @spec editor?() :: boolean()
  def editor? do
    is_function(Application.get_env(:troupe, :edit_file), 1) or
      Enum.any?(["VISUAL", "EDITOR"], &((System.get_env(&1) || "") |> String.trim() != ""))
  end
end
