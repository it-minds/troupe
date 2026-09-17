defmodule Troupe.Plane.Admin.Console do
  @moduledoc """
  Which console screen reaches each administrative method, and which deliberately do not.

  `Troupe.Plane.AdminParityTest` proves the context, the JSON-RPC surface and the MCP tools
  agree. Nothing proved the *console* did — which is exactly how `admin.profile.put` came to
  be in the TypeScript client and reachable from no screen at all. A capability that exists
  in the API and nowhere a person can click is a capability the product does not really have,
  and the way it happens is never a decision: somebody adds a method, the screen is a
  separate job, and the separate job does not happen.

  So it is written down here, beside the method table, and asserted by a test that fails on
  a new method. Adding a method now means answering one question — *where does somebody do
  this* — and `:api_only` is an allowed answer as long as it comes with a reason.

  ## What a reason has to be

  A sentence about why a person would not click it, not a note that the screen is not built
  yet. `admin.index.rebuild` is a recovery operation somebody runs from a shell during an
  incident; that is a reason. "No screen for this yet" is a backlog item wearing a reason's
  clothes, and the test cannot tell the difference — so the reasons are few, and each one
  should look wrong if it ever stops being true.

  ## Debt is named, not disguised

  `@owed` is the third answer, and it exists because the first two would have been lies on
  the day this was written. The console is eleven screens and the design is fifteen; a
  placement for a screen that does not exist is aspirational, and an `:api_only` reason for
  one that is merely unbuilt is the backlog item this module is supposed to make visible.

  So the debt is enumerated, each entry naming the screen it belongs on, and the test holds
  it to two rules: nothing may be owed that is not on this list, and nothing on this list
  may already be satisfied. The first stops a new method being quietly added to the debt.
  The second is what makes the list shrink — close a gap and the test fails until the entry
  is deleted, which is the opposite of a backlog that only grows.
  """

  @typedoc """
  Where an administrator does this.

  A screen name is one of `screens/0`, which are the names the navigation uses rather than
  module names: a screen that is split or renamed should not silently satisfy this.
  """
  @type placement :: {:screen, atom()} | {:api_only, String.t()}

  # The names in the navigation, grouped as the console groups them: what is happening, what
  # the product is, what it runs on.
  @watch ~w(overview sessions review audit)a
  @configure ~w(policy bundles profiles triggers teams identity integrations)a
  @operate ~w(fleet provisioners budgets connections)a

  @doc "Every screen name the console has, in the order the navigation shows them."
  @spec screens() :: [atom()]
  def screens, do: @watch ++ @configure ++ @operate

  @doc "The three groups, for a navigation that renders them as headings."
  @spec groups() :: [{String.t(), [atom()]}]
  def groups do
    [{"Watch", @watch}, {"Configure", @configure}, {"Operate", @operate}]
  end

  # Keyed by the context function rather than the method name, because the context is the
  # thing every surface renders and the method name is one surface's spelling of it.
  #
  # A screen here is a claim that somebody can do this thing there, and the test checks the
  # claim against what that screen's module actually calls. A map that said `:teams` for
  # something Teams does not call would be a worse lie than no map at all.
  #
  # **This records where somebody does each thing today, not where the design says it
  # belongs.** A map of the plan would pass a coverage test while the button did not exist,
  # which is the failure it was written to catch. Where the two differ, `owed/0` names the
  # move — so the plan is visible without being mistaken for the product.
  @placements %{
    # -- Watch ---------------------------------------------------------------
    overview: {:screen, :overview},
    sessions_list: {:screen, :sessions},
    session_erase: {:screen, :sessions},
    session_erase_preview: {:screen, :sessions},
    runs_list: {:screen, :triggers},
    audit_list: {:screen, :audit},
    audit_verify: {:screen, :audit},
    connections: {:screen, :connections},

    # -- Configure -----------------------------------------------------------
    settings_list: {:screen, :policy},
    setting_put: {:screen, :policy},
    setting_reset: {:screen, :policy},
    setting_effective: {:screen, :policy},
    bundles_list: {:screen, :bundles},
    bundle_get: {:screen, :bundles},
    bundle_validate: {:screen, :bundles},
    bundle_preview: {:screen, :bundles},
    bundle_publish: {:screen, :bundles},
    bundle_retire: {:screen, :bundles},
    profile_get: {:screen, :profiles},
    profile_put: {:screen, :profiles},
    preview: {:screen, :profiles},
    profile_delete: {:screen, :profiles},
    triggers_list: {:screen, :triggers},
    trigger_put: {:screen, :triggers},
    trigger_delete: {:screen, :triggers},
    trigger_run: {:screen, :triggers},
    trigger_revisions: {:screen, :triggers},
    trigger_key_rotate: {:screen, :triggers},
    teams_list: {:screen, :teams},
    team_enable: {:screen, :teams},
    team_update: {:screen, :teams},
    team_link: {:screen, :teams},
    team_unlink: {:screen, :teams},
    team_unlink_preview: {:screen, :teams},
    team_grant: {:screen, :teams},
    team_revoke: {:screen, :teams},
    team_admin_add: {:screen, :teams},
    team_admin_remove: {:screen, :teams},

    # Identity is its own screen in the design and lives inside two existing ones today.
    # Placed where it is; `owed/0` carries the move.
    groups_list: {:screen, :teams},
    identity_check: {:screen, :policy},
    principals_list: {:screen, :teams},
    principal_create: {:screen, :teams},
    principal_rotate: {:screen, :teams},
    principal_disable: {:screen, :teams},

    # Integrations likewise: checking whether a pod may reach an MCP host is a question the
    # profile editor asks while somebody is editing a profile.
    mcp_check: {:screen, :profiles},

    # -- Operate -------------------------------------------------------------
    pod_drain: {:screen, :fleet},
    provisioners: {:screen, :provisioners},
    profiles_list: {:screen, :fleet},
    provisioning_mode: {:screen, :profiles},
    person_budget: {:screen, :teams},
    budget_explain: {:screen, :budgets}
  }

  @doc """
  What the console owes, and the screen each thing belongs on.

  Every entry is a claim about where somebody *will* do this, made when the design named
  fifteen screens and eleven existed. The test checks both directions: an unplaced method
  must be here, and something here must not already work — so the list can only shrink.

  Deleting an entry is how a screen lands. Adding one to make a test pass is the thing this
  is meant to prevent, and is the one edit here that should be argued about.
  """
  @spec owed() :: %{atom() => atom()}
  def owed do
    %{
      # No way to delete a profile from the console. The editor edits one, reached by name
      # from the fleet screen, and creating is a route of its own.
      profile_delete: :profiles
    }
  end

  @doc """
  Screens the design names that do not exist, and what each would gather.

  Separate from `owed/0` because they are a different kind of debt: `owed/0` is a method
  with nowhere to be, and this is a screen with nothing of its own yet. Every method these
  would gather is reachable *somewhere* today — the console is not missing the capability,
  it is missing the place an administrator would look for it.
  """
  @spec unbuilt() :: %{atom() => String.t()}
  def unbuilt do
    %{
      review: "what ran unattended and needs a person; exists in the GUI, not here",
      identity:
        "the provider, claims, SCIM state and principals, which sit inside Policy and Teams",
      integrations: "org-level MCP servers and the egress allowlist as an object"
    }
  end

  @doc """
  Where each context function is reached from.

  A function missing from this map is the failure the coverage test exists to catch, so it
  is *absent* rather than defaulted: a default would make a new method quietly API-only.
  """
  @spec placements() :: %{atom() => placement()}
  def placements, do: @placements

  @doc "Where one function is reached from, or `nil` if nobody has said."
  @spec placement(atom()) :: placement() | nil
  def placement(function), do: Map.get(@placements, function)

  @doc "The functions a given screen claims to reach."
  @spec reached_by(atom()) :: [atom()]
  def reached_by(screen) do
    for {function, {:screen, ^screen}} <- @placements, do: function
  end

  @doc """
  Everything reachable from no screen, with the reason it is not.

  Short on purpose, and each entry should look wrong the moment it stops being true.
  """
  @spec api_only() :: [{atom(), String.t()}]
  def api_only do
    for {function, {:api_only, reason}} <- @placements, do: {function, reason}
  end
end
