defmodule Troupe.Operator.Controller.TeamVolume do
  @moduledoc """
  Where a `TeamVolume` event enters the operator.

  A team volume is a declaration that a team has shared storage. The claims that bind
  it into a namespace belong to the profiles that mount it — several profiles may be
  granted the same team — so this records the volume and leaves the binding to them.
  """

  use Bonny.ControllerV2

  alias Troupe.Operator.Reconcilers

  step :handle_event

  @spec handle_event(Bonny.Axn.t(), keyword()) :: Bonny.Axn.t()
  def handle_event(%Bonny.Axn{action: :delete} = axn, _opts) do
    Reconcilers.forget(axn.resource)
    axn
  end

  def handle_event(axn, _opts) do
    Reconcilers.reconcile(axn.conn, axn.resource)
    axn
  end
end
