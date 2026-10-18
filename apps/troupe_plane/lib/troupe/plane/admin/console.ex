defmodule Troupe.Plane.Admin.Console do
  @moduledoc """
  Where in the console each administrative method is done, and which deliberately are not.

  `Troupe.Plane.AdminParityTest` proves the context, the JSON-RPC surface and the MCP tools
  agree. Nothing proved the *console* did — which is exactly how `admin.profile.put` came to
  be in the TypeScript client and reachable from no screen at all. A capability that exists
  in the API and nowhere a person can click is a capability the product does not really have,
  and the way it happens is never a decision: somebody adds a method, the screen is a
  separate job, and the separate job does not happen.

  So it is written down here, beside the method table, and asserted by a test that fails on
  a new method. Adding a method now means answering one question — *where does somebody do
  this* — and `:api_only` is an allowed answer as long as it comes with a reason.

  ## The console is the one at `/console`

  The areas are the console's map (`clients/gui/apps/console/src/nav.ts`), in its four
  groups. The LiveView pages under `/admin` are the break-glass page and nothing else, and
  place nothing: what a break-glass session can do there is read, and put back what the
  deployment says about signing in.

  Two tests hold this to the console. `Troupe.Plane.ConsoleCoverageTest` fails on a method
  with no placement, and on a placement on an area the map does not have. The console's own
  `test/coverage.test.ts` reads this file and fails on a placement the console does not
  keep: a method it neither calls nor owes on that same area in its `owed.ts`, which is the
  console's account of what it has still to draw.

  ## What a reason has to be

  A sentence about why a person would not click it, not a note that the screen is not built
  yet. `admin.index.rebuild` is a recovery operation somebody runs from a shell during an
  incident; that is a reason. "No screen for this yet" is a backlog item wearing a reason's
  clothes, and belongs in the console's `owed.ts` with the area it will be drawn on.
  """

  @typedoc """
  Where an administrator does this: an area of the console's map, by the id the map gives
  it, or nowhere, with the reason.
  """
  @type placement :: {:area, atom()} | {:api_only, String.t()}

  # The console's map, as `nav.ts` has it: what is happening, what the product is, what it
  # runs on, and who may do what.
  @watch ~w(overview sessions connections runs)a
  @configure ~w(profiles bundles triggers integrations)a
  @operate ~w(pods hosts budgets)a
  @govern ~w(teams identity signin policy clients organisation audit memory)a

  @doc "Every area of the console's map, in the order the map shows them."
  @spec areas() :: [atom()]
  def areas, do: @watch ++ @configure ++ @operate ++ @govern

  @doc "The four groups, as the map heads them."
  @spec groups() :: [{String.t(), [atom()]}]
  def groups do
    [{"Watch", @watch}, {"Configure", @configure}, {"Operate", @operate}, {"Govern", @govern}]
  end

  # Keyed by the context function rather than the method name, because the context is the
  # thing every surface renders and the method name is one surface's spelling of it. A
  # function a screen reaches as well as its own area's (Teams lists groups to link) is
  # placed once, where an administrator would look for it first.
  @placements %{
    # -- Watch ---------------------------------------------------------------
    overview: {:area, :overview},
    sessions_list: {:area, :sessions},
    session_erase: {:area, :sessions},
    session_erase_preview: {:area, :sessions},
    connections: {:area, :connections},
    runs_list: {:area, :runs},
    run_review: {:area, :runs},

    # -- Configure -----------------------------------------------------------
    profiles_list: {:area, :profiles},
    profile_get: {:area, :profiles},
    profile_put: {:area, :profiles},
    preview: {:area, :profiles},
    profile_delete: {:area, :profiles},
    profile_choices: {:area, :profiles},
    provisioning_mode: {:area, :profiles},
    # Checking one host is a question the profile editor asks while somebody is editing a
    # profile; Integrations answers it for every host at once, which is a different question.
    mcp_check: {:area, :profiles},
    bundles_list: {:area, :bundles},
    bundle_get: {:area, :bundles},
    bundle_validate: {:area, :bundles},
    # The agent builder in the bundle editor asks it as an agent's fields are typed.
    agent_check: {:area, :bundles},
    bundle_preview: {:area, :bundles},
    bundle_publish: {:area, :bundles},
    bundle_retire: {:area, :bundles},
    triggers_list: {:area, :triggers},
    trigger_put: {:area, :triggers},
    trigger_delete: {:area, :triggers},
    trigger_run: {:area, :triggers},
    trigger_fix: {:area, :triggers},
    trigger_revisions: {:area, :triggers},
    trigger_key_rotate: {:area, :triggers},
    integrations: {:area, :integrations},
    github_get: {:area, :integrations},
    github_put: {:area, :integrations},
    github_check: {:area, :integrations},
    github_deliveries: {:area, :integrations},
    github_delete: {:area, :integrations},
    signing_get: {:area, :integrations},
    signing_rotate: {:area, :integrations},

    # -- Operate -------------------------------------------------------------
    pod_drain: {:area, :pods},
    # Beside the pods rather than in the editor: bootstrapping a repository is every
    # profile at once, and the page that lists every profile's workers is where somebody
    # about to do it is.
    profiles_export: {:area, :pods},
    provisioners: {:area, :hosts},
    hosts_list: {:area, :hosts},
    host_register: {:area, :hosts},
    host_rotate: {:area, :hosts},
    host_set_enabled: {:area, :hosts},
    person_budget: {:area, :budgets},
    budget_explain: {:area, :budgets},

    # -- Govern --------------------------------------------------------------
    teams_list: {:area, :teams},
    team_enable: {:area, :teams},
    team_update: {:area, :teams},
    team_link: {:area, :teams},
    team_unlink: {:area, :teams},
    team_unlink_preview: {:area, :teams},
    team_disable: {:area, :teams},
    team_disable_preview: {:area, :teams},
    team_grant: {:area, :teams},
    team_revoke: {:area, :teams},
    team_admin_add: {:area, :teams},
    team_admin_remove: {:area, :teams},
    groups_list: {:area, :identity},
    identity_duplicates: {:area, :identity},
    identity_adopt: {:area, :identity},
    principals_list: {:area, :identity},
    principal_create: {:area, :identity},
    principal_rotate: {:area, :identity},
    principal_disable: {:area, :identity},
    provider_get: {:area, :signin},
    provider_check: {:area, :signin},
    provider_put: {:area, :signin},
    provider_reset: {:area, :signin},
    scim_get: {:area, :signin},
    scim_rotate: {:area, :signin},
    scim_delete: {:area, :signin},
    scim_update: {:area, :signin},
    settings_list: {:area, :policy},
    setting_put: {:area, :policy},
    setting_reset: {:area, :policy},
    setting_effective: {:area, :policy},
    # Placed on Policy because that is where the value it gates is saved, and a save gated
    # on a check somewhere else is a gate somebody walks around.
    identity_check: {:area, :policy},
    clients_get: {:area, :clients},
    clients_put: {:area, :clients},
    audit_list: {:area, :audit},
    audit_verify: {:area, :audit},
    # The organisation's and the teams' documents are on Company memory; a profile's is
    # edited on the profile's own page as well, through the same three.
    memory_list: {:area, :memory},
    memory_get: {:area, :memory},
    memory_preview: {:area, :memory},
    memory_put: {:area, :memory}
  }

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

  @doc "The functions an area claims to reach."
  @spec reached_by(atom()) :: [atom()]
  def reached_by(area) do
    for {function, {:area, ^area}} <- @placements, do: function
  end

  @doc """
  Everything reachable from no area, with the reason it is not.

  Short on purpose, and each entry should look wrong the moment it stops being true.
  """
  @spec api_only() :: [{atom(), String.t()}]
  def api_only do
    for {function, {:api_only, reason}} <- @placements, do: {function, reason}
  end
end
