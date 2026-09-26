defmodule Troupe.Plane.Fleet.Provisioner.SSH do
  @moduledoc """
  Workers on machines somebody already has.

  *Your script creates the workspace, we connect to it.* The contract is a host that
  answers, not a host we built — so this provisioner creates nothing, reaches nothing, and
  holds no key. Somebody registers a machine against the profile, installs the worker on it
  however they install things, and the worker dials the plane exactly as a pod does.

  That asymmetry is deliberate and is what makes the single-developer case work: the laptop
  already exists, it is behind NAT, and the plane could not reach it if it wanted to. The
  plane's half is a secret it can check and a row it can list.

  ## `ensure/2` cannot make a machine, and says so rather than retrying

  A profile wanting four workers on a substrate with two registered hosts is not a
  transient condition the next tick will fix. It is somebody who has to go and install the
  worker on two more machines. So this reports the shortfall instead of failing, and the
  scaler treats a shortfall as the fleet being as large as it can be — which is true, and
  which keeps `session.create` on the waiting path rather than the refusing one.

  ## No guarantees, listed individually

  A host is not in a cluster, so there is no admission policy, no NetworkPolicy, no Cilium
  FQDN egress and no disruption budget. `guarantees/1` returns the empty list and the
  console names all four, because *unenforced* is not a useful thing to tell somebody
  deciding whether their team's work may run here.

  This is for the developer with one laptop and the team with one build box. It is not a
  way around the policy: `Troupe.Plane.Settings.Ladder` refuses to place a team on such a
  profile unless a platform admin has said otherwise for that team.
  """

  @behaviour Troupe.Plane.Fleet.Provisioner

  alias Troupe.Plane.Drain
  alias Troupe.Plane.Fleet.{Host, Hosts, Profile}

  require Logger

  @impl true
  def name, do: "ssh"

  @doc """
  None of them. A host is a machine, not a cluster.

  Every one of these is enforced by Kubernetes whether or not the plane is running, which
  is what the rest of the design leans on. Somewhere without it, the honest answer is a
  list of four things, not a flag.
  """
  @impl true
  def guarantees(%Profile{}, _opts \\ []), do: []

  @doc """
  Reconcile the profile against its inventory, which is all there is to reconcile.

  Returns what the profile asked for, what is registered and enabled, and the shortfall.
  A shortfall is a fact to show somebody, not an error: nothing the plane does next will
  change it.
  """
  @impl true
  def ensure(%Profile{} = profile, _opts) do
    available = profile.name |> Hosts.for_profile() |> Enum.filter(&Host.enrollable?/1)
    wanted = profile.replicas || 0
    short = max(wanted - length(available), 0)

    if short > 0 do
      Logger.info(
        "troupe plane: #{profile.name} wants #{wanted} worker(s) and has #{length(available)} " <>
          "registered host(s); register #{short} more to grow it"
      )
    end

    {:ok,
     %{
       state: :applied,
       profile: profile.name,
       wanted: wanted,
       available: length(available),
       short: short
     }}
  end

  @doc """
  The same drain sequence as everywhere else, and then nothing.

  Stop placing, let running turns finish, get everything into object storage. The machine
  stays: it was somebody's before this and it is somebody's after. Nothing is removed from
  object storage, which is done item 4 and is a property of the sequence rather than of
  this provisioner.
  """
  @impl true
  def drain(worker, opts), do: Drain.pod(worker, opts)

  @doc """
  The inventory, which is what this substrate has to say about what exists.

  A host that is registered and has never enrolled appears here and not in the fleet, and
  that gap is the useful part: it is the state somebody debugging an install is in.
  """
  @impl true
  def describe(%Profile{} = profile) do
    {:ok,
     profile.name
     |> Hosts.for_profile()
     |> Enum.map(&%{name: &1.name, profile: &1.profile, address: &1.address, ordinal: nil})}
  end
end
