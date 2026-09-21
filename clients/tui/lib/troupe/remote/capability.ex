defmodule Troupe.Remote.Capability do
  @moduledoc """
  What a remote session lets you do right now, and why not when it does not.

  One function, used in two places that must agree: the worker publishes it as
  a `:remote_status` event so the view can grey a control out without asking
  anything at render time, and `Troupe.Client.capability/1` answers with it when
  a caller asks directly.
  """

  @type t :: %{
          state: atom(),
          scopes: [String.t()],
          can_input?: boolean(),
          can_approve?: boolean(),
          reason: String.t() | nil,
          up?: boolean(),
          remote?: boolean()
        }

  @doc "The capability of a session in `state`, with `scopes`, on a connection that is `up?`."
  @spec of(atom(), [String.t()], boolean()) :: t()
  def of(state, scopes, up?) do
    {can?, reason} =
      cond do
        state == :read_only -> {false, "this session is read-only"}
        state == :erased -> {false, "this session has been erased"}
        not up? -> {false, "reconnecting to the worker"}
        "control" not in scopes -> {false, "your token only has the observe scope"}
        true -> {true, nil}
      end

    %{
      state: state,
      scopes: scopes,
      can_input?: can?,
      can_approve?: can?,
      reason: reason,
      up?: up?,
      remote?: true
    }
  end
end
