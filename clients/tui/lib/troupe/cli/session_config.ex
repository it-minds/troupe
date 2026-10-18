defmodule Troupe.CLI.SessionConfig do
  @moduledoc """
  `troupe config --explain [KEY] [--json] --session SESSION_ID`: what is in force in a
  running session, and where each part came from, as `troupe config --explain` says it of
  this machine's files.

  A running session's configuration was resolved as it started, so only where it runs can
  say it: this machine's daemon for one of its own, and for a session on a worker pod the
  pod, over the session's own connection, which the plane this machine is signed in to
  opens without waking it. On a pod that is its worker profile's settings and rules, what
  the platform enforces, the terms it was created with and its repository's files. The
  daemon is asked first; a session it does not have is asked of the plane.
  """

  alias Troupe.Client.Daemon.Link
  alias Troupe.Client.Remote
  alias Troupe.Remote.Worker

  @typedoc """
  Where the answer comes from, so a test can play both: `daemon` asks this machine's
  daemon, `pod` the session's worker pod; each answers `config.get`'s result or an error.
  """
  @type io :: %{
          daemon: (map() -> {:ok, map()} | {:error, term()}),
          pod: (String.t(), map() -> {:ok, map()} | {:error, term()})
        }

  @doc "The explanation and the exit status, as `Troupe.Config.explain/3` answers them."
  @spec explain(String.t(), String.t() | nil, keyword(), io()) :: {String.t(), non_neg_integer()}
  def explain(session_id, key, opts \\ [], io \\ io()) do
    json? = Keyword.get(opts, :json, false)

    params =
      %{session_id: session_id, explain: if(json?, do: "json", else: "text")}
      |> then(&if(key, do: Map.put(&1, :key, key), else: &1))

    case io.daemon.(params) do
      {:ok, answer} ->
        shown(answer, json?)

      {:error, reason} ->
        if not_here?(reason),
          do: on_a_pod(session_id, params, json?, io),
          else: {"could not ask this machine's daemon: #{describe(reason)}\n", 1}
    end
  end

  defp on_a_pod(session_id, params, json?, io) do
    case io.pod.(session_id, params) do
      {:ok, answer} ->
        shown(answer, json?)

      {:error, reason} ->
        if not_here?(reason),
          do:
            {"session #{session_id} is not running, here or on a worker pod; its configuration is " <>
               "resolved when it starts, so open it and ask again\n", 1},
          else: {"could not ask the session's worker pod: #{describe(reason)}\n", 1}
    end
  end

  defp shown(%{"explain" => explained, "explain_status" => status}, true) when is_map(explained),
    do: {Jason.encode!(explained, pretty: true) <> "\n", status}

  defp shown(%{"explain" => text, "explain_status" => status}, _json?) when is_binary(text),
    do: {text, status}

  # A daemon or a pod older than the explanation answers the keys alone.
  defp shown(_answer, _json?),
    do: {"the daemon or pod running this session is too old to explain its configuration\n", 1}

  defp not_here?(%{message: message}) when message in ["not_found", "forbidden"], do: true
  defp not_here?(%{"message" => message}), do: not_here?(%{message: message})
  defp not_here?(reason) when reason in [:no_plane, :logged_out, :not_found], do: true
  defp not_here?(_reason), do: false

  defp describe(%{message: message} = error), do: "#{message}#{data(error[:data])}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp data(%{"reason" => reason}), do: ": #{reason}"
  defp data(%{reason: reason}), do: ": #{reason}"
  defp data(_data), do: ""

  @doc "This machine's daemon, and the plane last signed in to for a session on a pod."
  @spec io() :: io()
  def io, do: %{daemon: &Link.call("config.get", &1), pod: &pod/2}

  # Opened to read, which wakes nothing: a session asleep has no configuration in force.
  defp pod(session_id, params) do
    with {:remote, plane} <- Remote.default_plane() || {:error, :no_plane},
         {:ok, origin} <- Remote.connect(plane),
         {:ok, _sid} <- Remote.open_session(origin, session_id, :read, []) do
      try do
        Worker.rpc(session_id, "config.get", params)
      after
        Worker.detach(session_id)
      end
    end
  end
end
