defmodule Troupe.Protocol.Relay do
  @moduledoc """
  What a person on another device may ask of a laptop's session through the plane.

  A laptop's daemon offers one of its sessions to the plane over a connection it dials
  itself, and the plane relays protocol messages between that connection and the people
  the session is offered to. Both ends check every message they relay against this one
  table: the plane before it sends a message on, and the laptop's daemon again before its
  dispatcher sees it, against its own record of whom it offered the session to. One table
  in the protocol app, because the plane may not call the daemon's code and the daemon may
  not call the plane's (`mix troupe.boundaries`), and two lists would drift.

  **The session and nothing else.** Every method here is about the offered session, and a
  message naming another (as `session_id`, a branch's `parent`, or the id in a `session:`
  or `presence:` topic) is refused, so is `fleet`. Nothing about the laptop is here: no
  file is read or written (`fs.*`), no command of the person's own runs (`shell.*`), no
  tool of a remote person's machine is offered (`tools.*`), and no setting, server,
  workspace or identity of the laptop is read or changed.

  **The laptop's rules hold.** A remote prompt is a prompt: the session's enforced layer,
  per-tool rules and approvals apply to it as to one typed at the laptop. An approval
  answered remotely is `allow` or `deny` for that one call; `allow_session`, which would
  stop the session asking for that tool, is the laptop's person's to give at the laptop.

  **A private session, with its owner's consent.** A private session is sealed under its
  person's key, and the relay carries what an offered session says through the plane
  unsealed. So it is offered only after its owner has said yes to that, in the words below
  (`private_consent/0`), which every client shows the same; while it is offered, only the
  people invited into it with `control` steer it, and withdrawing the offer makes it
  sealed-only again.
  """

  alias Troupe.Protocol.Error

  # Each method a relayed connection may call, and the scope it needs. `observe` reads the
  # session, `control` steers it; nothing over the relay is `admin`.
  @methods %{
    "subscribe" => :observe,
    "unsubscribe" => :observe,
    "session.get" => :observe,
    "session.list" => :observe,
    "session.goal.get" => :observe,
    "session.loop.get" => :observe,
    "blob.get" => :observe,
    "agents.list" => :observe,
    "commands.list" => :observe,
    "presence.set" => :observe,
    "input.send" => :control,
    "commands.run" => :control,
    "turn.cancel" => :control,
    "profile.switch" => :control,
    "approval.respond" => :control,
    "question.answer" => :control,
    "todo.edit" => :control
  }

  # Belong to the connection rather than the session, and are answered where the
  # connection ends: `initialize` by the laptop, `auth.refresh` by the plane, which holds
  # the token and never passes one to the laptop.
  @connection ~w(initialize auth.refresh)

  @roles ~w(observe control)

  @private_consent "This session is private: while it is offered, what it says and does passes " <>
                     "through the plane unsealed, and the plane relays it to whoever you invited " <>
                     "with control. The plane keeps none of it. Offer it?"

  @private_withdrawn "The owner withdrew the offer: this private session is sealed-only again, " <>
                       "and what it says no longer passes through the plane."

  @invitation_taken_back "Your invitation into this private session was taken back: you no " <>
                           "longer steer it."

  @doc "Every method a relayed connection may call, with the scope it needs."
  @spec methods() :: %{String.t() => :observe | :control}
  def methods, do: @methods

  @doc "The roles a session may be offered to a person with: `observe` or `control`."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc """
  What a private session's owner is asked before it is offered: that while it is offered,
  what it says passes through the plane unsealed, to the people invited with `control`.
  The terminal, the desktop app and the docs say these words.
  """
  @spec private_consent() :: String.t()
  def private_consent, do: @private_consent

  @doc "What closes a view of a private session whose offer was withdrawn."
  @spec private_withdrawn() :: String.t()
  def private_withdrawn, do: @private_withdrawn

  @doc "What closes a view of a private session once the person's invitation is taken back."
  @spec invitation_taken_back() :: String.t()
  def invitation_taken_back, do: @invitation_taken_back

  @doc "The scopes a role carries over the relay."
  @spec scopes(String.t()) :: [:observe | :control]
  def scopes("control"), do: [:observe, :control]
  def scopes(_observe), do: [:observe]

  @doc "The narrower of two roles: what both ends of the relay agree a person may do."
  @spec narrower(String.t() | nil, String.t() | nil) :: String.t() | nil
  def narrower(nil, _other), do: nil
  def narrower(_one, nil), do: nil
  def narrower("control", "control"), do: "control"
  def narrower(_one, _other), do: "observe"

  @doc """
  Whether a message from a remote person may go on to the session.

  `:ok`, or the refusal to answer with. `session_id` is the offered session and `role`
  what this end holds the person to. A message that is not a request (an answer, a
  notification) carries no method and is left to the protocol.
  """
  @spec check(String.t(), map(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def check(method, _params, _session_id, _role) when method in @connection, do: :ok

  def check(method, params, session_id, role) do
    with {:ok, needed} <- method_scope(method),
         :ok <- held(needed, role),
         :ok <- confined(params, session_id) do
      decision(method, params)
    end
  end

  defp method_scope(method) do
    case Map.fetch(@methods, method) do
      {:ok, scope} -> {:ok, scope}
      :error -> {:error, Error.new(:forbidden, %{method: method, reason: not_relayed(method)})}
    end
  end

  defp not_relayed(method) do
    "#{method} is not done through the plane: a session offered for steering takes " <>
      "prompts, answers and its agent from another device, and nothing else of the laptop"
  end

  defp held(needed, role) do
    if needed in scopes(role),
      do: :ok,
      else: {:error, Error.new(:forbidden, %{required_scope: Atom.to_string(needed)})}
  end

  # Every place a request names a session. A listing names none and is narrowed to the
  # offered session where it is answered; `fleet` is every session on the laptop.
  defp confined(params, session_id) when is_map(params) do
    named =
      params
      |> Map.take(["session_id", "parent"])
      |> Enum.reject(fn {_field, id} -> id in [nil, ""] end)
      |> then(fn named -> topic(params["topic"], named) end)

    case Enum.find(named, fn {_field, id} -> id != session_id end) do
      nil -> :ok
      {field, _other} -> {:error, Error.new(:forbidden, %{field: field, reason: "another session"})}
    end
  end

  defp confined(_params, _session_id), do: :ok

  defp topic(topic, named) when is_binary(topic) do
    case String.split(topic, ":", parts: 2) do
      [kind, id] when kind in ["session", "presence"] -> [{"topic", id} | named]
      _fleet_or_other -> [{"topic", topic} | named]
    end
  end

  defp topic(_topic, named), do: named

  # Named by the agents of a path on the laptop rather than the session's own, a listing
  # is about the laptop; and `allow_session` would loosen what the session asks.
  defp decision("agents.list", %{"workspace" => _path}) do
    {:error, Error.new(:forbidden, %{field: "workspace", reason: "the session's own agents only"})}
  end

  defp decision("approval.respond", %{"decision" => "allow_session"}) do
    {:error,
     Error.new(:forbidden, %{
       field: "decision",
       reason:
         "allowing a tool for the rest of the session is done at the laptop; " <>
           "from another device a call is allowed or denied once"
     })}
  end

  defp decision(_method, _params), do: :ok
end
