defmodule Troupe.Gateway.Sensitive do
  @moduledoc """
  A sensitive session on this computer, as the daemon keeps it (#1239).

  A session here is marked as a pod's is, in its log, by the gate of its own agents
  (`Troupe.Tools.authorize/4`) against this computer's `sensitive` (the organisation's
  enforced file and the person's own `config.yaml`, `Troupe.Config.Layers`), or by its
  person's hand (`session.sensitive.set`, `session.create` with `sensitive: true`). Nothing
  clears it. What the daemon does for a session outside that gate it holds to the same
  rules, read through the same functions:

    * a publication (`publish_artifact`'s, or a client's `artifact.publish` naming the
      session) is refused where `deny` names `publish_artifact`;
    * a proposal for a team's or the organisation's memory is refused whatever `deny` says,
      as the plane refuses a sensitive pod session's;
    * an offer for steering from another device, and an invitation into a private session,
      are refused where `sharing` is `ask` or `deny`: on a laptop `ask` refuses too, since
      no team administrator answers a laptop's request;
    * the daemon's own `mcp.call` for a session here marks it where the call matches
      `marked_by`, and is refused once it is sensitive where it matches `deny`.

  A session not running here is read from its row (the index folds the mark from its log)
  and its workspace's configuration as it resolves now.
  """

  alias Troupe.Config.Permissions
  alias Troupe.Protocol.{Error, Sensitive}
  alias Troupe.Session.Sensitive, as: Mark
  alias Troupe.Tools

  @doc "The session's mark, running or not: `%{at, by, how, ...}`, or `nil`."
  @spec mark_of(String.t() | nil) :: map() | nil
  def mark_of(nil), do: nil

  def mark_of(session_id) do
    Mark.mark_of(session_id) ||
      case Troupe.get_session(session_id) do
        %{sensitive: %{} = mark} -> mark
        _none -> nil
      end
  end

  @doc """
  The session's `sensitive` configuration: what its tree started with, or for one not
  running here what its workspace's configuration says now; `nil` where nothing is set.
  """
  @spec config_of(String.t() | nil) :: map() | nil
  def config_of(nil), do: nil

  def config_of(session_id) do
    Mark.config(session_id) ||
      with %{workspace: workspace} when is_binary(workspace) <- Troupe.get_session(session_id),
           {:ok, config, _layers} <- Troupe.Config.resolve(workspace) do
        config.sensitive
      else
        _none -> nil
      end
  end

  @doc """
  Mark a session here sensitive by its person's hand, one-way: its tree must be running
  (the mark is a line of its log). Answers the mark, the first one where it already was.
  """
  @spec mark_by_hand(String.t(), String.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, :no_session}
  def mark_by_hand(session_id, subject, name) do
    data =
      %{"how" => "person", "by" => subject || "unknown"}
      |> then(fn data -> if name, do: Map.put(data, "display_name", name), else: data end)

    Mark.mark(session_id, data)
  end

  @doc "`session.sensitive.set`'s `sensitive`: only `true`, since nothing clears the mark."
  @spec one_way(term()) :: :ok | {:error, Error.t()}
  def one_way(true), do: :ok

  def one_way(false),
    do:
      invalid(
        "nothing clears a sensitive session's mark, not its person and not an administrator: " <>
          "it is sensitive until it is erased"
      )

  def one_way(_other), do: invalid("sensitive is true")

  defp invalid(reason), do: {:error, Error.new(:invalid_params, %{field: "sensitive", reason: reason})}

  @doc """
  Whether a sensitive session may be shared beyond the people who read it now (an offer, an
  invitation): `:ok`, or `forbidden` with the sentence where its `sharing` is `ask` or
  `deny`.
  """
  @spec sharing(String.t() | nil) :: :ok | {:error, Error.t()}
  def sharing(session_id) do
    with %{} <- mark_of(session_id),
         %{sharing: word} = config when word in ["ask", "deny"] <- config_of(session_id) do
      reason = Sensitive.laptop_sharing_refused(word, whose_sharing(config))
      {:error, Error.new(:forbidden, %{reason: reason, sensitive: true})}
    else
      _shared -> :ok
    end
  end

  defp whose_sharing(%{sharing_from: %{layer: layer, source: source}}),
    do: Permissions.scope(%{layer: layer, source: source})

  defp whose_sharing(_config), do: "this computer's configuration"

  @doc """
  The sentence a call the daemon makes for a session is refused with where the session is
  sensitive and its `deny` names the tool, or `nil`: the gate's own refusal and words.
  """
  @spec refusal(String.t() | nil, String.t(), map()) :: String.t() | nil
  def refusal(session_id, tool, args \\ %{}) do
    with %{} = mark <- mark_of(session_id),
         {:denied_sensitive, _tool, _rule, _mark} = refused <-
           Tools.sensitive_refusal(config_of(session_id), mark, tool, args) do
      Troupe.Tool.Result.describe(refused)
    else
      _none -> nil
    end
  end

  @doc """
  The daemon's own call of a tool for a session running here (`mcp.call`): marked first
  where it matches `marked_by`, as the gate marks, then refused where the session is
  sensitive and `deny` names it. `:ok` to make the call, or the refusal's sentence.
  """
  @spec call(String.t() | nil, String.t(), map()) :: :ok | {:refused, String.t()}
  def call(nil, _tool, _args), do: :ok

  def call(session_id, tool, args) do
    _mark = Tools.mark_sensitive(Mark.config(session_id), session_id, tool, args)

    case refusal(session_id, tool, args) do
      nil -> :ok
      sentence -> {:refused, sentence}
    end
  end
end
