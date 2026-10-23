defmodule Troupe.Plane.Admin.API do
  @moduledoc """
  The admin JSON-RPC methods, and nothing behind them.

  Every entry here is a rename: a method name to a `Troupe.Plane.Admin` function and its
  arguments. That is deliberate and is the point of the module — if a method needed logic
  of its own, the panel and everything else would not be getting the same behaviour, and
  the parity this whole arrangement exists to guarantee would be a claim rather than a
  fact.

  `Troupe.Plane.AdminParityTest` enumerates `Admin` and asserts each function appears
  here and in the MCP tool list.

  ## Why the table carries prose and types

  It did not always. It was a method name, a function and a list of argument names, which
  is everything a dispatcher needs and nothing a *caller* does — and there are now four
  callers, one of which is a language model reaching the platform over MCP. A model
  choosing between `admin.team.revoke` and `admin.profile.delete` has whatever the tool
  description says and nothing else, so the description is not documentation about the
  interface, it *is* the interface, and it belongs where the method is declared rather
  than in a second table somebody has to remember to update.

  So each method carries a summary, a typed argument list and a risk.
  `Troupe.Plane.Admin.MCP` projects them into JSON Schema; the parity test asserts none of
  it is missing. A method added without a summary fails the test rather than reaching a
  model as a bare name.

  `risk` is the honest one:

  * `:read` answers a question and changes nothing.
  * `:write` changes configuration. Reversible by making the opposite change.
  * `:destructive` destroys something, or stops something that is running. `confirm` names
    the argument whose value a caller must echo back — the erase dialog's rule, which the
    design gives as the model for everything irreversible, applied to a caller that has no
    dialog to read.
  """

  alias Troupe.Plane.{Admin, ClientVersions}
  alias Troupe.Plane.Admin.API.{Argument, Method}
  alias Troupe.Plane.Fleet.Provisioner
  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Triggers.Trigger
  alias Troupe.Protocol.Error

  # -- the shapes that appear in more than one method -------------------------

  # A profile's spec, as `admin.profile.put` takes it.
  @profile_properties [
    %Argument{
      name: "name",
      type: :string,
      required: true,
      description: "The profile's name, which is also the name of its WorkerProfile resource."
    },
    %Argument{
      name: "image",
      type: :string,
      description:
        "The worker image, as repository:tag or repository@sha256:digest. A digest pins it; a tag does not. Or the word release: the worker image of the release this plane is running, which the plane writes again after every upgrade so the profile moves with the platform. release is refused on a plane deployed without a worker image. Needed unless extends names a profile, whose image is then this one's where it sets none."
    },
    %Argument{
      name: "extends",
      type: :string,
      description:
        "The one profile this one extends, or null for none. The plane resolves the two into the profile in effect, which is all the cluster sees: egress.fqdns, egress.gitHosts and MCP servers are added to the parent's (a server with a parent's name replaces it only with override: true); on a channel of its own, its pods load one bundle, the parent's with its channel's agents, skills, MCP servers and ACP agents added, an entry with a parent's name replacing it only where that channel's document says override: true; max_sessions and budget_micros are the lower of the two, and a budget_micros above the parent's is refused; permissions.deny, ask and allow are added to the parent's, which a child cannot drop; a parent's personalTools forbid and repositoryOverridesBundle false hold whatever this one says; image, size_class, provisioner, the llm fields, the channel and every other spec field are the parent's where this one sets none; llm.secretRef, mcpIdentities, warm_workers and grants are never inherited. Send only what differs from the parent: what this profile sets stops following the parent. A chain is at most four profiles; a missing parent or a cycle is refused. Puts are refused on a gitops plane, where a manifest names its parent in spec.extends and the plane writes the profile in effect into its status."
    },
    %Argument{
      name: "size_class",
      type: :string,
      description:
        "How demanding a session is here: standard (several share a worker) or heavy (fewer, with more CPU, memory and disk each). A resource question, not a safety one — sessions cannot see each other's files whatever the class."
    },
    %Argument{
      name: "max_sessions",
      type: :integer,
      description:
        "How far this may grow, in sessions at once rather than workers. Absent is no ceiling, bounded by the team's budget. A session refused here is told this number."
    },
    %Argument{
      name: "budget_micros",
      type: :integer,
      description:
        "What this profile's sessions may spend in a calendar month (UTC, turning over on the 1st), in millionths of a dollar, whoever starts them and in whichever team: a ceiling beside the person's, the team's and the platform's, and a session it refuses is told it is the profile's. Absent, null or 0 is no ceiling. A profile that extends another can only lower its parent's: the lower of the two is in effect, and one higher than the parent's is refused."
    },
    %Argument{
      name: "warm_workers",
      type: :integer,
      description:
        "How many workers to keep up when nothing is running. 0 scales to zero, which costs the next session a cold start of roughly half a minute."
    },
    %Argument{
      name: "provisioner",
      type: :string,
      values: Provisioner.names(),
      description:
        "What makes the workers exist: kubernetes (the default; the operator runs pods) or ssh (machines registered with admin.host.register, which dial the plane; nothing is written to the cluster). A profile on ssh gives none of the cluster's guarantees, and a team may be granted it only once a platform admin has allowed that team unenforced workers."
    },
    %Argument{
      name: "spec",
      type: :object,
      description:
        "The rest of the WorkerProfile spec, in the resource's own camelCase: llm, egress, mcpServers, configBundleChannel, orgMount, repositoryOverridesBundle, personalTools, github, permissions, storage.storageClassName. permissions is per-tool rules every session on the profile's pods obeys, as config's: {\"deny\": [\"shell(curl)\"], \"ask\": [\"mcp(issues.delete)\"], \"allow\": [...]}; an enforced layer, the strictest rule that matches a call holding, so a session's own configuration cannot loosen them, and a shell deny refuses a command a person types with ! there too; a rule the pods could not read is refused. mcpServers are the profile's own servers, which its pods load beside its bundle's: the resource's list is the bundle's with these added by name, one with a bundle server's name replacing it only with override: true, and a publish to the channel composes the two again rather than overwriting these; servers sent back that are the bundle's are dropped as the bundle's. configBundleChannel is the bundle channel the profile follows, stable where absent. repositoryOverridesBundle true lets a session's working copy replace the bundle's agents and skills, and the built-in agents, of the same name with its own; absent or false, those win and the working copy's are skipped and listed. personalTools is allow (the default, also when absent) or forbid: forbid has the profile's pods refuse a person's offer of their own signed-in tools (tools.register), saying why. github.permissions is what a session's token may do on GitHub beyond cloning, in GitHub's names: contents (read or write: write pushes its troupe/* branch), pull_requests (read or write: write opens its draft pull request and comments), checks and statuses (read: its CI); absent, sessions clone and do no more. Every llm field but endpoint needs llm.endpoint, without which the pods are given none of them, and is refused without it. llm.prices is dollars per million tokens by model, as {\"<model>\": {\"input\": 0.5, \"output\": 1.5}}, for models the gateway does not price: a model with no price counts as free against every budget. storage.storageClassName is the storage class a worker's disk comes from, one the cluster policy allows; absent is the cluster's default. mcpIdentities says who the profile is at each server its bundle calls with client credentials: {server, clientId, scope, tokenUrl, transitKey, keyVersion, certificateThumbprint, algorithm}, none of it secret; the answer's identity_problems lists a server the bundle marks client_credentials that has none, or an identity that is incomplete. Replicas, sessionsPerPod, resources and storage.size are not among them: the plane writes those from the size class and from what is running. Read the profile first and send it back changed rather than composing one from nothing."
    }
  ]

  # A component's version policy, as `admin.clients.put` takes it (Decision 868).
  @client_policy_properties [
    %Argument{
      name: "recommended",
      type: :string,
      description:
        "The version clients are nudged to, and the one troupe update installs for a person signed in here. Null for none."
    },
    %Argument{
      name: "minimum",
      type: :string,
      description:
        "The oldest version this plane serves; an older client is refused and told to run troupe update. Not newer than recommended. Null for none."
    },
    %Argument{
      name: "blocked",
      type: :array,
      description:
        "Versions this plane serves to nobody, whatever their number: a release with a defect. The whole list; the recommended version may not be on it."
    }
  ]

  # The plane's GitHub App, as `admin.github.put` takes it.
  @github_properties [
    %Argument{
      name: "app_id",
      type: :integer,
      description: "The App ID GitHub shows on the App's settings page. Null clears it."
    },
    %Argument{
      name: "api_url",
      type: :string,
      description:
        "Where GitHub's API is: https://api.github.com (the default, also when null), https://api.<name>.ghe.com for GitHub Enterprise Cloud, or https://<host>/api/v3 for GitHub Enterprise Server. Clones come from the matching host, which a worker profile must declare in egress.gitHosts."
    },
    %Argument{
      name: "installations",
      type: :array,
      description:
        "Every installation the plane may use, as [{\"owner\": \"example-org\", \"installation_id\": 123}]: the organisation or account the App is installed on, and the number at the end of that installation's settings URL. The whole list; a session may name a repository only of an owner listed here."
    },
    %Argument{
      name: "private_key",
      type: :string,
      description:
        "The App's private key, the PEM file GitHub downloads, as text. Imported into OpenBao's transit engine as a key that cannot be exported; a key already there gets this one as its next version, and the plane signs with the newest. Blank or absent leaves the key as it is."
    },
    %Argument{
      name: "webhook_secret",
      type: :string,
      description:
        "The secret typed into the App's webhook settings, at least 32 characters (openssl rand -hex 32 makes one). Imported into OpenBao's transit engine as an HMAC key that cannot be exported, and checked against every delivery's X-Hub-Signature-256 at POST /webhook/github. A secret already there gets this one as its next version. Blank or absent leaves it as it is."
    }
  ]

  # Which memory document: the organisation's, a team's or a worker profile's.
  @memory_document [
    %Argument{
      name: "scope",
      type: :string,
      required: true,
      values: Troupe.Protocol.Memory.scopes(),
      description:
        "Whose document: organisation (every session's), team (that team's sessions and its members' machines) or profile (the sessions on that worker profile's pods)."
    },
    %Argument{
      name: "name",
      type: :string,
      description: "The team's or the profile's name. Not for the organisation's."
    }
  ]

  @memory_text %Argument{
    name: "text",
    type: :string,
    required: true,
    description:
      "The whole document, as Markdown or plain text, at most 8192 bytes. Empty clears it."
  }

  @filter_properties [
    %Argument{name: "limit", type: :integer, description: "How many rows at most."},
    %Argument{name: "team", type: :string, description: "Narrow to one team, by name."},
    %Argument{name: "profile", type: :string, description: "Narrow to one profile."},
    %Argument{
      name: "state",
      type: :string,
      description: "Narrow to sessions in one state: active, dormant or read_only."
    },
    %Argument{name: "actor", type: :string, description: "Narrow to one actor's changes."},
    %Argument{name: "kind", type: :string, description: "Narrow to one kind of audit entry."},
    %Argument{name: "subject_id", type: :string, description: "Narrow to one changed thing."},
    %Argument{name: "channel", type: :string, description: "Narrow to one bundle channel."},
    %Argument{name: "trigger", type: :string, description: "Narrow to one trigger's runs."},
    %Argument{name: "status", type: :string, description: "Narrow to runs of one status."},
    %Argument{name: "origin", type: :string, description: "Narrow to one origin."},
    %Argument{
      name: "needs_review",
      type: :boolean,
      description: "Only sessions an unattended run left for a person to look at."
    }
  ]

  @team_properties [
    %Argument{
      name: "budget_micros",
      type: :integer,
      description:
        "The team's spend ceiling per period, in millionths of a currency unit. 0 is unlimited."
    },
    %Argument{
      name: "budget_period",
      type: :string,
      values: Team.budget_periods(),
      description:
        "What the ceiling is measured over: monthly, which turns over on the 1st of the month (UTC), or never for one that does not turn over."
    },
    %Argument{
      name: "idle_timeout_seconds",
      type: :integer,
      description:
        "How long a session sits idle before its actors are released and it goes dormant."
    },
    %Argument{
      name: "cache_eviction_days",
      type: :integer,
      description: "How long a dormant session keeps its cache."
    },
    %Argument{
      name: "erase_after_days",
      type: :integer,
      description: "How long a session is kept at all before it is erased."
    },
    %Argument{
      name: "members_may_control",
      type: :boolean,
      description: "Whether team visibility lets a member steer a session or only watch it."
    },
    %Argument{
      name: "pins_allowed",
      type: :boolean,
      description: "Whether members may pin a session against eviction."
    },
    %Argument{
      name: "remote_offering_allowed",
      type: :boolean,
      description:
        "Whether the team's people may offer a laptop session for steering from another device. False refuses each new offer, and each attach to one already made, saying the team does not allow it."
    },
    %Argument{
      name: "volume_size",
      type: :string,
      description: "The team volume's size, as a Kubernetes quantity such as 10Gi."
    },
    %Argument{
      name: "volume_storage_class",
      type: :string,
      description: "The storage class the team volume is provisioned from."
    },
    %Argument{
      name: "allow_unenforced_workers",
      type: :boolean,
      description:
        "Whether this team may be granted a profile whose workers run where nothing is enforced (machines rather than a cluster). A platform admin's to set; refused from a team admin, and refused as false while the team holds such a grant."
    },
    %Argument{
      name: "github",
      type: :object,
      description:
        "What the team's sessions may do on GitHub through the plane's App. Only the keys sent change; null clears them all. A team that lists no repository names none, and the App's installations bound every list.",
      properties: [
        %Argument{
          name: "repositories",
          type: :array,
          description:
            "The repositories the team's sessions and triggers may name, each owner/name or owner/* for every repository of the owner. A session, a trigger or a token for one not listed is refused."
        },
        %Argument{
          name: "max_pushes",
          type: :integer,
          description:
            "Pushes a run may make, 1 to 1000; the lower of this and the profile's github.maxPushes holds. A run at its cap is stopped, with a comment on its pull request. Null for no cap of the team's."
        },
        %Argument{
          name: "max_runs",
          type: :integer,
          description:
            "Runs on a repository the team's triggers may have going at once, 1 to 1000; a firing over it is skipped. Null for no cap of the team's."
        },
        %Argument{
          name: "max_attempts",
          type: :integer,
          description:
            "Runs a sweep may start on one issue that end without a fix before it leaves the issue for a person, 1 to 1000; the lower of this and the profile's github.maxAttempts holds, and one where neither is set. A person asking again (the label, the command, or admin.trigger.fix) starts the count again. Null for no cap of the team's."
        }
      ]
    }
  ]

  # Enabling a team takes its name as well, which updating one does not.
  @team_enable_properties [
    %Argument{
      name: "name",
      type: :string,
      description:
        "The team's name, which grants, sessions and principals are addressed by. Absent, it is made from the group's."
    }
    | @team_properties
  ]

  @principal_properties [
    %Argument{
      name: "name",
      type: :string,
      required: true,
      description: "What this principal is for."
    },
    %Argument{
      name: "description",
      type: :string,
      description: "A sentence about what it does, for whoever finds it in a listing later."
    },
    %Argument{
      name: "sponsor",
      type: :string,
      required: true,
      description:
        "The subject of a person in this team who is answerable for what it does. " <>
          "A principal whose sponsor leaves stops firing at the next SCIM push."
    },
    %Argument{
      name: "profiles",
      type: :array,
      description:
        "The profiles it may start sessions on. Empty means every profile the team has."
    }
  ]

  @trigger_properties [
    %Argument{
      name: "team",
      type: :string,
      required: true,
      description: "The team the trigger belongs to."
    },
    %Argument{
      name: "name",
      type: :string,
      required: true,
      description:
        "The trigger's name, unique within the team: lowercase letters, digits and dashes."
    },
    %Argument{
      name: "principal",
      type: :string,
      description:
        "The service principal its sessions run as, by subject: svc:<team>/<name>, of this team. Needed to create one."
    },
    %Argument{
      name: "profile",
      type: :string,
      description:
        "The profile its sessions start on: one this plane has and the principal may use. Needed to create one."
    },
    %Argument{
      name: "agent",
      type: :string,
      description: "The primary agent. Absent is the profile's default."
    },
    %Argument{
      name: "enabled",
      type: :boolean,
      description: "Whether it fires at all, by schedule or by hand. true where absent."
    },
    %Argument{
      name: "source",
      type: :object,
      description: "What is expected to fire it. Needed to create one.",
      properties: [
        %Argument{
          name: "kind",
          type: :string,
          values: Trigger.source_kinds(),
          required: true,
          description:
            "schedule (fired by cron), webhook (fired at POST /trigger/<id> with its own key, minted when the trigger is created and answered once; or, naming a repository, by the GitHub App's signed deliveries) or manual (fired only by hand)."
        },
        %Argument{
          name: "cron",
          type: :string,
          description:
            "For a schedule: five fields, minute hour day-of-month month day-of-week, in UTC."
        },
        %Argument{
          name: "tz",
          type: :string,
          description:
            "For a schedule: UTC, the only zone this plane keeps. Another is refused rather than ignored."
        },
        %Argument{
          name: "provider",
          type: :string,
          description:
            "For a webhook: who sends it, for the executor that receives it; github for a trigger on a repository."
        },
        %Argument{
          name: "repository",
          type: :string,
          description:
            "For a webhook from GitHub: the repository, owner/name, one the plane's GitHub App is installed on and the profile declares the Git host for. Its sessions are created with it, and the trigger is fired by the App's deliveries, with no key."
        },
        %Argument{
          name: "label",
          type: :string,
          description:
            "For a trigger on a repository: an issue given this label starts a run (issues.labeled)."
        },
        %Argument{
          name: "command",
          type: :string,
          description:
            "For a trigger on a repository: a comment on an issue whose first line is this, such as /troupe fix, by the repository's owner, a member or a collaborator, starts a run (issue_comment.created)."
        },
        %Argument{
          name: "ref",
          type: :string,
          description:
            "For a trigger on a repository: the branch its sessions clone. The default branch where absent."
        },
        %Argument{
          name: "sweep",
          type: :string,
          description:
            "For a trigger on a repository: a five-field cron in UTC at whose minutes the plane goes over the repository's open issues, those with label or those query finds, oldest first and at most 50, and starts a run on each that no run is fixing (a run going, or an open pull request a run opened) and that its runs have not tried as often as github.maxAttempts allows, under the trigger's concurrency and the profile's and team's caps. A sweep stops at the first run a cap skips."
        },
        %Argument{
          name: "query",
          type: :string,
          description:
            "For a sweep: GitHub's issue search qualifiers instead of the label, such as label:bug no:assignee. The plane adds the repository and is:issue is:open; repo:, org:, user:, is:, type:, state: and archived: are refused."
        }
      ]
    },
    %Argument{
      name: "prompt_template",
      type: :string,
      description:
        "What each session is asked to do, with {{event.*}}, {{trigger.*}} and {{run.*}} placeholders. A missing path renders empty; nothing is escaped."
    },
    %Argument{
      name: "terms",
      type: :object,
      description:
        "What an unattended session may spend, as session.create checks it. Absent are the defaults.",
      properties: [
        %Argument{
          name: "budget_micros",
          type: :integer,
          description:
            "Reserved at each activation, in millionths of a currency unit; capped to what the team has left."
        },
        %Argument{name: "max_turns", type: :integer, description: "1 to 500."},
        %Argument{name: "wall_clock_seconds", type: :integer, description: "60 to 86400."},
        %Argument{
          name: "approvals",
          type: :string,
          values: ~w(wait deny),
          description: "wait leaves an approval for a person; deny answers no. There is no auto."
        }
      ]
    },
    %Argument{
      name: "visibility",
      type: :string,
      values: ~w(private team),
      description: "Who may see its sessions. team where absent."
    },
    %Argument{
      name: "review",
      type: :string,
      values: ~w(required none),
      description:
        "Whether a person is expected to look at each run (admin.run.review). required where absent."
    },
    %Argument{
      name: "notify",
      type: :array,
      description: "Subjects granted collaborator on every run's session."
    },
    %Argument{
      name: "notify_url",
      type: :string,
      description:
        "An absolute http or https URL told when a run ends. Loopback and link-local are refused, and the host must be one this deployment's egress policy allows."
    },
    %Argument{
      name: "concurrency",
      type: :integer,
      description:
        "The cap on live runs, 1 to 100; a firing over it is recorded as skipped. 1 where absent."
    }
  ]

  @methods [
    %Method{
      name: "admin.overview",
      function: :overview,
      summary:
        "Fleet health, active sessions and spend per team, scoped to what the caller administers. The first call to make.",
      risk: :read
    },
    %Method{
      name: "admin.profiles.list",
      function: :profiles_list,
      summary:
        "Every profile, with its pods, conditions and load. On a gitops plane each carries `gitops`: the repository it comes from, the resource generation it was read at, and any problem the last pass reported — `refused` (the resource fails the plane's checks and is not used, with the reasons), `missing` (a row the cluster has no resource for), `plane_only` (nothing applies it from a repository yet) or `unwritten`. A refused resource with no row is listed too.",
      risk: :read
    },
    %Method{
      name: "admin.profile.choices",
      function: :profile_choices,
      summary:
        "What a profile's fields may be: every provider type llm.provider may name, with what each asks for (where it is, whether it needs a key), and every size class with how many sessions share a worker and what it is for. The lists the plane checks a profile against, so a form offers no choice it would refuse. And models, each {name, why}: the models this plane knows a provider serves, from the profile's own model, the models the organisation gives people's machines, the models sessions (the profile's, with profile) have run on, and the models its bundle's agents name; the plane does not ask a provider for its list.",
      risk: :read,
      arguments: [
        %Argument{
          name: "profile",
          type: :string,
          description:
            "A profile's name: its own model, its sessions' and its bundle's are in models. Without it, the organisation's and every session's."
        }
      ]
    },
    %Method{
      name: "admin.profile.agents",
      function: :profile_agents,
      summary:
        "A profile's agents, as its bundle in effect has them (composed through what it extends), for the console's builder: each with its mode, description, model, delegate (the subagents it may hand work to: its bundle's, when it holds the delegate tool), max_turns, skills, permissions, from (the profile whose channel gave it) and channel, builtin (a primary Troupe ships that the profile offers because its bundle has none of that name), its definition, and teams, each team granted the profile with may (whether its grant lets it run the agent). Beside them channel, the one the profile follows in effect, builtins, every agent Troupe ships with its definition, to copy from, and teams. A platform admin's, as editing a bundle is.",
      risk: :read,
      arguments: [
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The profile's name."
        }
      ]
    },
    %Method{
      name: "admin.profiles.export",
      function: :profiles_export,
      summary:
        "Every profile, the cluster policy, every trigger and the GitHub App as a repository would hold them, to bootstrap one before switching a plane to gitops mode: a path and the YAML for each, and notes where something needs deciding first. Left out of every profile's manifest is what the plane or the cluster writes (spec.replicas, spec.teams, spec.mcpServers, the troupe.dev/drained annotation, status), listed in left_out: a repository must not hold them. A trigger's manifest has no key, runs or revisions, which stay with the plane. The GitHubApp's (github) has the App's ID, API URL and installations and each team's repositories and caps, and never its private key or webhook secret, which stay in OpenBao.",
      risk: :read
    },
    %Method{
      name: "admin.hosts.list",
      function: :hosts_list,
      summary:
        "Every machine registered to a profile, with whether it has ever enrolled. Registered-and-never-seen is its own state: a worker nobody has installed yet is a different job from a machine that is off.",
      risk: :read,
      arguments: [
        %Argument{
          name: "profile",
          type: :string,
          required: true,
          description: "The profile the hosts belong to."
        }
      ]
    },
    %Method{
      name: "admin.host.register",
      function: :host_register,
      summary:
        "Register a machine against a profile and mint the secret it enrols with. The secret is returned once and stored only as a hash; there is no method that shows it again. The answer also carries ca, the PEM of the CA that signed the control port's certificate, which the machine pins: it enrols over TLS only. Refused while the control port has no certificate.",
      risk: :write,
      arguments: [
        %Argument{
          name: "profile",
          type: :string,
          required: true,
          description: "The profile whose policy this machine runs under."
        },
        %Argument{
          name: "host",
          type: :object,
          required: true,
          description: "The machine: a name of your choosing, and optionally an address.",
          properties: [
            %Argument{
              name: "name",
              type: :string,
              required: true,
              description: "What you call this machine. Unique within the profile."
            },
            %Argument{
              name: "address",
              type: :string,
              description:
                "Where it is, for your own records. The plane never dials a host — the worker dials the plane."
            }
          ]
        }
      ]
    },
    %Method{
      name: "admin.host.rotate",
      function: :host_rotate,
      summary:
        "Mint a new enrolment secret for a machine, keeping the machine. The old secret stops working immediately, and the new one is shown once, with ca as registering answers it.",
      risk: :write,
      arguments: [
        %Argument{name: "profile", type: :string, required: true, description: "The profile."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The machine's name."
        }
      ]
    },
    %Method{
      # No underscore: an MCP tool name is this with the dots swapped for underscores, and
      # `set_enabled` would not survive the trip back.
      name: "admin.host.enabled",
      function: :host_set_enabled,
      summary:
        "Stop a machine enrolling, or let it again. Nothing here reaches the machine: a worker already connected keeps its sessions until it is drained.",
      risk: :write,
      arguments: [
        %Argument{name: "profile", type: :string, required: true, description: "The profile."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The machine's name."
        },
        %Argument{
          name: "enabled",
          type: :boolean,
          required: true,
          description: "Whether it may enrol."
        }
      ]
    },
    %Method{
      name: "admin.provisioners.list",
      function: :provisioners,
      summary:
        "What can make a worker, and which guarantee each substrate does not give: admission policy, network policy, egress by hostname, disruption budget. Where a weaker one stands in for a missing one, `instead` names it: Kubernetes has egress by hostname only where the operator reports Cilium for a profile, and otherwise the allowlist checked at admission. A profile on a substrate that gives none of them may only be granted to a team a platform admin has allowed.",
      risk: :read
    },
    %Method{
      name: "admin.profile.get",
      function: :profile_get,
      summary:
        "One profile in full: the spec that was asked for, what policy makes of it, and what is actually running. Read this before changing one. For a profile that extends another, spec and written are what it sets itself, which is what to send back, and profile is the profile in effect; extended_by names the profiles that extend this one.",
      risk: :read,
      arguments: [
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The profile's name."
        },
        %Argument{
          name: "effective",
          type: :boolean,
          description:
            "With true, the answer's effective is the profile in effect, resolved through what it extends: the chain, the profile, and fields, each path and value with the profile it came from, and problems the resolution reports (a parent's key or server this one has no credential of its own for)."
        }
      ]
    },
    %Method{
      name: "admin.profile.put",
      function: :profile_put,
      summary:
        "Create or update a profile, returning the diff that was applied. Refused on a gitops plane as managed_by_gitops: there a repository holds the profiles, and a change is a commit to it. Refused as invalid_params, with Cilium or without, for a profile whose workers are pods and whose LLM endpoint, MCP servers (its own or its channel's) or egress.fqdns name a loopback or link-local address, which those pods do not reach: `unreachable` names each, `reason` says what to do. Without Cilium, one on another port, or at another address, gets a rule of its own in the pods' NetworkPolicy. A change to a profile others extend rewrites each of them as it now resolves, after checking each as a put of it would be, and is audited once with extended_by naming them; the answer's extended_by has each one's changes and provisioning.",
      risk: :write,
      arguments: [
        %Argument{
          name: "profile",
          type: :object,
          required: true,
          description:
            "The profile to write. Absent fields are not preserved: send the whole thing.",
          properties: @profile_properties
        }
      ]
    },
    %Method{
      name: "admin.profile.preview",
      function: :preview,
      summary:
        "What policy makes of a profile and what would change, without writing anything. The same check admission makes. A profile that extends another is judged as it would be in effect; extended_by lists every profile below this one as the write would leave it, each with its changes, the policy's verdict and a problem that would refuse the write.",
      risk: :read,
      arguments: [
        %Argument{
          name: "profile",
          type: :object,
          required: true,
          description: "The profile as it would be written.",
          properties: @profile_properties
        }
      ]
    },
    %Method{
      name: "admin.profile.delete",
      function: :profile_delete,
      summary:
        "Remove a profile. Sessions on it become read-only rather than being erased, and its pods go away. Refused on a gitops plane as managed_by_gitops, except for a row the cluster has no resource for (reported missing), which it deletes and nothing else. Refused as conflict while other profiles extend it, naming them in extended_by.",
      risk: :destructive,
      confirm: "name",
      arguments: [
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The profile's name."
        }
      ]
    },
    %Method{
      name: "admin.pod.drain",
      function: :pod_drain,
      summary:
        "Drain a pod: it stops taking new sessions and hands back what it was holding. Reversible, and sessions are moved rather than lost.",
      risk: :destructive,
      confirm: "worker_id",
      arguments: [
        %Argument{
          name: "worker_id",
          type: :string,
          required: true,
          description: "The worker's id, as admin.profiles.list reports it."
        }
      ]
    },
    %Method{
      name: "admin.teams.list",
      function: :teams_list,
      summary: "Teams, with their grants, budgets, volumes, retention and spend.",
      risk: :read
    },
    %Method{
      name: "admin.team.enable",
      function: :team_enable,
      summary:
        "Make an identity-provider group into a team. Enabling is the only thing Troupe adds to a group: membership stays the provider's. A name another team already has is refused as conflict unless link is true, because under it the group would be linked into that team and the team's settings changed; enabling a team's own group again is the same team, and a setting sent that differs from the team's is refused as conflict too, naming it in `settings`, unless link is true (a team's settings change with admin.team.update). A team that exists takes only the settings sent; the plane's defaults are a new team's.",
      risk: :write,
      arguments: [
        %Argument{
          name: "group",
          type: :string,
          required: true,
          description: "The group's external id in the identity provider."
        },
        %Argument{
          name: "attrs",
          type: :object,
          description:
            "The team's name, and anything to set at the same time, as in admin.team.update.",
          properties: @team_enable_properties
        },
        %Argument{
          name: "link",
          type: :boolean,
          description:
            "true to link the group into the team that already has the name, changing its settings to those sent. Absent or false refuses that name, and refuses settings that differ from those of a team the group is already in."
        }
      ]
    },
    %Method{
      name: "admin.team.update",
      function: :team_update,
      summary:
        "Change a team's budget, retention, volume, default visibility, or the GitHub repositories its sessions may name and its fix loop's caps.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "attrs",
          type: :object,
          required: true,
          description:
            "The fields to change, of those below. Anything not named is left alone, and a key that is not one of them is ignored: a team's name and the group it was enabled from are not changed here.",
          properties: @team_properties
        }
      ]
    },
    %Method{
      name: "admin.groups.list",
      function: :groups_list,
      summary:
        "Every identity-provider group this plane knows about, which is what a team links to. A group that looks like another one held twice carries `looks_duplicated`: the other group's identifier and the mismatch it most likely comes from.",
      risk: :read
    },
    %Method{
      name: "admin.identity.duplicates",
      function: :identity_duplicates,
      summary:
        "People and groups that look like one held twice: the same email or display name under different keys. Each set says which rows, where each came from (a sign-in or SCIM), and the mismatch it most likely comes from. Nothing is merged on this evidence.",
      risk: :read
    },
    %Method{
      name: "admin.identity.adopt",
      function: :identity_adopt,
      summary:
        "Settle a refused adoption that admin.identity.duplicates lists by external_id: the row SCIM gave the subject as its externalId is that person's. A row a sign-in made under the subject is folded into SCIM's row, which takes the subject; with none, the next push or sign-in adopts SCIM's row. It hands that row, with its sessions and administration, to whoever signs in under the subject.",
      risk: :destructive,
      confirm: "subject",
      arguments: [
        %Argument{
          name: "row",
          type: :string,
          required: true,
          description: "The id of the row SCIM gave the externalId, as the listing names it."
        },
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The externalId, which is the subject the sign-in or push came under."
        }
      ]
    },
    %Method{
      name: "admin.team.link",
      function: :team_link,
      summary:
        "Draw a team's members from one more identity-provider group. Membership stays the provider's; this says which groups count.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "group",
          type: :string,
          required: true,
          description: "The group's identifier, as the provider spells it."
        }
      ]
    },
    %Method{
      name: "admin.team.unlink.preview",
      function: :team_unlink_preview,
      summary:
        "What unlinking a group would do: how many people are in the team only through it, how many keep access another way, and how many sessions they can currently open. Read this first.",
      risk: :read,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "group",
          type: :string,
          required: true,
          description: "The group's identifier."
        }
      ]
    },
    %Method{
      name: "admin.team.unlink",
      function: :team_unlink,
      summary:
        "Stop drawing a team's members from a group. Removes access for everybody who was in the team only through it. Sessions do not move: their team is fixed at create.",
      risk: :destructive,
      confirm: "group",
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "group",
          type: :string,
          required: true,
          description: "The group's identifier."
        }
      ]
    },
    %Method{
      name: "admin.team.disable.preview",
      function: :team_disable_preview,
      summary:
        "What removing a team would take with it: its grants, administrators, service principals, triggers and group links, and how many sessions stay behind with no team. Read this first.",
      risk: :read,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."}
      ]
    },
    %Method{
      name: "admin.team.disable",
      function: :team_disable,
      summary:
        "Remove a team. Its grants are revoked, its sessions go read-only, and its administrators, service principals, triggers and group links go with it. The people and the groups stay; the sessions stay, with no team.",
      risk: :destructive,
      confirm: "name",
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."}
      ]
    },
    %Method{
      name: "admin.team.grant",
      function: :team_grant,
      summary: "Give a team access to a profile. Effective for sessions started after it.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "profile",
          type: :string,
          required: true,
          description: "The profile's name."
        },
        %Argument{
          name: "attrs",
          type: :object,
          description:
            "Grant options: the volume mode the team gets on this profile, and " <>
              "`entitlements`, a list of `{kind, name, mode}` narrowing which of the " <>
              "bundle's agents, skills and MCP servers this team gets. No entitlements " <>
              "means no restriction; sending the key replaces the whole list."
        }
      ]
    },
    %Method{
      name: "admin.team.revoke",
      function: :team_revoke,
      summary:
        "Take a profile away from a team. Sessions already running on it become read-only rather than stopping.",
      risk: :destructive,
      confirm: "profile",
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "profile",
          type: :string,
          required: true,
          description: "The profile's name."
        }
      ]
    },
    %Method{
      name: "admin.team.admin.add",
      function: :team_admin_add,
      summary: "Make somebody an administrator of one team.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The person's subject, as their identity provider issues it."
        }
      ]
    },
    %Method{
      name: "admin.team.admin.remove",
      function: :team_admin_remove,
      summary: "Take the team-admin role away. The person keeps their membership of the team.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The person's subject."
        }
      ]
    },
    %Method{
      name: "admin.integrations.list",
      function: :integrations,
      summary:
        "What this plane talks to that is not a person: MCP servers carried by more than one profile, every host anything here dials with whether the cluster policy allows it, and each trigger's notification target with the rule it is held to.",
      risk: :read
    },
    %Method{
      name: "admin.run.review",
      function: :run_review,
      summary:
        "Mark the run behind a session as looked at, by whoever is asking. What Review is for: a run that ended badly and that nobody has read is the state that screen exists to empty.",
      risk: :write,
      arguments: [
        %Argument{
          name: "session_id",
          type: :string,
          required: true,
          description: "The session the run created."
        }
      ]
    },
    %Method{
      name: "admin.audit.verify",
      function: :audit_verify,
      summary:
        "Check the audit trail's hash chain and name the first row that does not verify: altered content, or a predecessor that is not the one that was there. result is ok, or that row with its reason (altered or chain_broken). Rows written before the chain existed are counted as unchained rather than reported as bad.",
      risk: :read
    },
    %Method{
      name: "admin.connections.list",
      function: :connections,
      summary:
        "Who has connected a personal credential to which person-mode server, and whose identity each session carries. Whether a slot is filled, never what is in it: there is no method that reads or removes somebody's credential.",
      risk: :read,
      arguments: [
        %Argument{
          name: "team",
          type: :string,
          description: "One team's, or every team you administer if left out."
        }
      ]
    },
    %Method{
      name: "admin.sessions.list",
      function: :sessions_list,
      summary:
        "Session metadata: who, which profile, what state, what it cost. Never content — there is no method that returns content.",
      risk: :read,
      arguments: [
        %Argument{
          name: "filter",
          type: :object,
          description: "Narrowing, all optional.",
          properties: @filter_properties
        }
      ]
    },
    %Method{
      name: "admin.session.erase.preview",
      function: :session_erase_preview,
      summary:
        "What erasing a session will do, before doing it: how much it holds, that its key is destroyed in every version so no backup recovers the content, and how many forks survive it. A fork is a separate session with its own key and is not erased with its parent.",
      risk: :read,
      arguments: [
        %Argument{
          name: "session_id",
          type: :string,
          required: true,
          description: "The session's id."
        }
      ]
    },
    %Method{
      name: "admin.session.erase",
      function: :session_erase,
      summary:
        "Erase a session and everything it holds. Irreversible: no snapshot restores it, the owner is not notified, spend already recorded stays in the month's total, and the audit record of the erasure survives with your name on it.",
      risk: :destructive,
      confirm: "session_id",
      arguments: [
        %Argument{
          name: "session_id",
          type: :string,
          required: true,
          description: "The session's id."
        }
      ]
    },
    %Method{
      name: "admin.provider.get",
      function: :provider_get,
      summary:
        "The identity provider: every sign-in setting with its value and where it came from (a secret as set or not), the URLs to register at the provider, and how many people have arrived through it.",
      risk: :read,
      arguments: []
    },
    %Method{
      name: "admin.provider.check",
      function: :provider_check,
      summary:
        "Test a candidate provider without saving it: discovery answers and names itself the same, its keys can be read, and the endpoints given agree with the ones it publishes. Fields left out are today's values.",
      risk: :read,
      arguments: [
        %Argument{
          name: "attrs",
          type: :object,
          description:
            "Any of issuer, client_id, authorization_endpoint, device_authorization_endpoint, token_endpoint, laid over the current configuration."
        }
      ]
    },
    %Method{
      name: "admin.provider.put",
      function: :provider_put,
      summary:
        "Save the identity provider. Refused unless admin.provider.check passes for these values, or force is true. A blank field is left as it was; the secret is never returned or written to the audit trail.",
      risk: :write,
      arguments: [
        %Argument{
          name: "attrs",
          type: :object,
          required: true,
          description:
            "Any of issuer, client_id, client_secret, authorization_endpoint, device_authorization_endpoint, token_endpoint, scopes (space- or comma-separated), mcp_scope."
        },
        %Argument{
          name: "force",
          type: :boolean,
          description: "Save although the check failed. For a provider that is down right now."
        }
      ]
    },
    %Method{
      name: "admin.provider.reset",
      function: :provider_reset,
      summary:
        "Put every sign-in setting back to what this plane was deployed with. The way back from a provider saved in error.",
      risk: :write,
      arguments: []
    },
    %Method{
      name: "admin.scim.get",
      function: :scim_get,
      summary:
        "The SCIM connector: the URL the provider pushes to, whether a token is set and where, when it was rotated, when the provider last pushed, and whether pushed groups become teams. Never the token.",
      risk: :read,
      arguments: []
    },
    %Method{
      name: "admin.scim.rotate",
      function: :scim_rotate,
      summary:
        "Mint the SCIM connector's token and return it, once. The previous token stops working immediately; paste the new one into the provider.",
      risk: :write,
      arguments: []
    },
    %Method{
      name: "admin.scim.delete",
      function: :scim_delete,
      summary:
        "Forget the SCIM connector's token. Every push presenting it answers 401 until a new one is made. A token in the deployment's own environment is not touched.",
      risk: :destructive,
      confirm: "base_url",
      arguments: [
        %Argument{
          name: "base_url",
          type: :string,
          required: true,
          description: "This plane's SCIM base URL, exactly as admin.scim.get reports it."
        }
      ]
    },
    %Method{
      name: "admin.scim.update",
      function: :scim_update,
      summary:
        "Change the connector's switch. `teams_from_groups` true makes a pushed group a team on arrival, named from its display name with the platform's defaults; false leaves it a group until somebody enables it. Off creates no more teams and deletes none.",
      risk: :write,
      arguments: [
        %Argument{
          name: "attrs",
          type: :object,
          required: true,
          description: "`{teams_from_groups: boolean}`."
        }
      ]
    },
    %Method{
      name: "admin.bundles.list",
      function: :bundles_list,
      summary: "Every version of a configuration channel, newest first.",
      risk: :read,
      arguments: [
        %Argument{
          name: "channel",
          type: :string,
          required: true,
          description: "The channel, such as stable."
        }
      ]
    },
    %Method{
      name: "admin.bundle.get",
      function: :bundle_get,
      summary: "One version of a channel: its document, its summary and its hash.",
      risk: :read,
      arguments: [
        %Argument{name: "channel", type: :string, required: true, description: "The channel."},
        %Argument{
          name: "version",
          type: :integer,
          required: true,
          description: "The version number."
        }
      ]
    },
    %Method{
      name: "admin.bundle.validate",
      function: :bundle_validate,
      summary:
        "Check a bundle without publishing it: its shape, and whether policy lets a pod reach the MCP servers it names.",
      risk: :read,
      arguments: [
        %Argument{
          name: "content",
          type: :object,
          required: true,
          description: "The bundle document: agents, skills and mcp_servers."
        }
      ]
    },
    %Method{
      name: "admin.agent.check",
      function: :agent_check,
      summary:
        "Check one agent's definition as a bundle's agent is checked, by the rules the daemon's agents.validate applies: {ok, errors, warnings}, each finding with its field. Writes nothing.",
      risk: :read,
      arguments: [
        %Argument{
          name: "name",
          type: :string,
          description: "The name it would have in the bundle, checked when given."
        },
        %Argument{
          name: "definition",
          type: :string,
          required: true,
          description: "The definition: Markdown with YAML frontmatter, as a bundle's agent carries it."
        }
      ]
    },
    %Method{
      name: "admin.bundle.preview",
      function: :bundle_preview,
      summary:
        "What publishing this document would change against the channel's current version, and which teams lose an entitlement because an entry they are allowed no longer exists. Read this before publishing: it is the same diff the audit record is written from.",
      risk: :read,
      arguments: [
        %Argument{
          name: "channel",
          type: :string,
          required: true,
          description: "The channel, such as stable."
        },
        %Argument{
          name: "content",
          type: :object,
          required: true,
          description: "The bundle document, as `admin.bundle.publish` takes it."
        },
        %Argument{
          name: "from",
          type: :integer,
          description:
            "Compare against this published version instead of the channel's current one."
        }
      ]
    },
    %Method{
      name: "admin.bundle.publish",
      function: :bundle_publish,
      summary:
        "Publish a new version of a channel, which pushes config.updated to every pod on it. History is append-only: a rollback is a new version carrying the old content. Refused, with Cilium or without, for an MCP server at a loopback or link-local address when a profile whose workers are pods follows the channel.",
      risk: :write,
      arguments: [
        %Argument{name: "channel", type: :string, required: true, description: "The channel."},
        %Argument{
          name: "content",
          type: :object,
          required: true,
          description: "The bundle document: agents, skills and mcp_servers."
        }
      ]
    },
    %Method{
      name: "admin.bundle.retire",
      function: :bundle_retire,
      summary: "Retire a version, so nothing new starts on it. Running sessions are untouched.",
      risk: :write,
      arguments: [
        %Argument{name: "channel", type: :string, required: true, description: "The channel."},
        %Argument{
          name: "version",
          type: :integer,
          required: true,
          description: "The version to retire."
        }
      ]
    },
    %Method{
      name: "admin.mcp.check",
      function: :mcp_check,
      summary: "Whether the cluster's egress policy lets a pod reach an MCP server at this URL.",
      risk: :read,
      arguments: [
        %Argument{name: "url", type: :string, required: true, description: "The server's URL."}
      ]
    },
    %Method{
      name: "admin.audit.list",
      function: :audit_list,
      summary:
        "Who changed what, newest first, with the diff of each change. A team admin reads the rows about the teams they administer (the team, its triggers, principals and sessions); a platform admin reads them all.",
      risk: :read,
      arguments: [
        %Argument{
          name: "filter",
          type: :object,
          description: "Narrowing, all optional.",
          properties: @filter_properties
        }
      ]
    },
    %Method{
      name: "admin.provisioning.mode",
      function: :provisioning_mode,
      summary:
        "Whether this plane writes profiles to the cluster itself (direct) or reads them and the triggers from resources a repository holds (gitops), where a write to either is refused. Worth knowing before writing one.",
      risk: :read
    },
    %Method{
      name: "admin.settings.list",
      function: :settings_list,
      summary:
        "Every platform setting: what it is set to, where that value came from, and what changing it would do.",
      risk: :read
    },
    %Method{
      name: "admin.setting.put",
      function: :setting_put,
      summary:
        "Change one platform setting. Some take effect on the next call and some at the next restart; the answer says which.",
      risk: :write,
      arguments: [
        %Argument{
          name: "key",
          type: :string,
          required: true,
          description: "The setting's key, as admin.settings.list reports it."
        },
        %Argument{
          name: "value",
          type: :string,
          required: true,
          description:
            "The new value, written as a string. It is parsed against the setting's type and refused if it does not fit."
        }
      ]
    },
    %Method{
      name: "admin.setting.effective",
      function: :setting_effective,
      summary:
        "For one setting decided at more than one rung: the value in force, which rung decided it, and every rung that had an opinion.",
      risk: :read,
      arguments: [
        %Argument{
          name: "key",
          type: :string,
          required: true,
          description: "The setting's key."
        },
        %Argument{
          name: "team",
          type: :string,
          description:
            "Include this team's own rung. Absent answers for the rungs above every team."
        }
      ]
    },
    %Method{
      name: "admin.setting.reset",
      function: :setting_reset,
      summary:
        "Drop a setting's stored value, so it goes back to whatever this plane was deployed with.",
      risk: :write,
      arguments: [
        %Argument{name: "key", type: :string, required: true, description: "The setting's key."}
      ]
    },
    %Method{
      name: "admin.clients.get",
      function: :clients_get,
      summary:
        "Which versions of its clients this plane serves, per component (tui, daemon, desktop): the recommended version, the minimum, the blocked list, and who set them last. A client below the minimum or on a blocked version is refused at initialize with update_required.",
      risk: :read,
      arguments: []
    },
    %Method{
      name: "admin.clients.put",
      function: :clients_put,
      summary:
        "Change one component's version policy. Only the keys sent change, null clears one, and blocked is the whole list. Versions are written as releases are numbered (0.13.0-beta). A client is held to it at its next initialize: raising the minimum turns away every older client of that component.",
      risk: :write,
      arguments: [
        %Argument{
          name: "component",
          type: :string,
          required: true,
          values: ClientVersions.components(),
          description:
            "Which client: tui (the terminal, troupe), daemon (troupe-daemon) or desktop (the desktop app)."
        },
        %Argument{
          name: "policy",
          type: :object,
          required: true,
          description: "The keys to change.",
          properties: @client_policy_properties
        }
      ]
    },
    %Method{
      name: "admin.signing.get",
      function: :signing_get,
      summary:
        "The key this plane signs what it tells people's machines with (the version policy, the organisation's defaults and limits): an Ed25519 key in OpenBao transit that cannot be exported, its public half, its fingerprint (SHA256:...) and when it was made, and every version's. Machines pin it at sign-in; a person checks the fingerprint against this. Made on first use.",
      risk: :read,
      arguments: []
    },
    %Method{
      name: "admin.signing.rotate",
      function: :signing_rotate,
      summary:
        "Make a new version of the plane's signing key, which signs from then on. Every machine that pinned the old one refuses what the new one signs until its person accepts the new fingerprint. Confirmed by the current key's fingerprint.",
      risk: :destructive,
      confirm: "fingerprint",
      arguments: [
        %Argument{
          name: "fingerprint",
          type: :string,
          required: true,
          description: "The current key's fingerprint, SHA256:..., typed back to confirm."
        }
      ]
    },
    %Method{
      name: "admin.releases.list",
      function: :releases_list,
      summary:
        "The releases kept in this plane's object store, which people's machines update from at <plane>/downloads with no way to GitHub: each version mirrored, newest first, with how many files it holds, any whose copy is under way, where releases are mirrored from (source) and where machines are told to get them (release_url, null for GitHub's).",
      risk: :read,
      arguments: []
    },
    %Method{
      name: "admin.releases.mirror",
      function: :releases_mirror,
      summary:
        "Copy a release into this plane's object store from where releases are published, for people's machines to update from. Its manifest is checked against the release keys first: one they did not sign, or one naming another version, is refused and nothing is copied. The files are then copied in the background, each held to the manifest, and the release is listed as mirrored once its manifest is written, last. Machines check every file against the release key again before installing it.",
      risk: :write,
      arguments: [
        %Argument{
          name: "version",
          type: :string,
          required: true,
          description:
            "The release's version, as it is numbered: 0.24.0-beta (a leading v is taken off)."
        }
      ]
    },
    %Method{
      name: "admin.memory.list",
      function: :memory_list,
      summary:
        "Every memory document you may read: the organisation's, each team's you administer (every team's for a platform admin) and, for a platform admin, each worker profile's; each with the version in force, who saved it and when, its size, and whether you may change it, and the limit in bytes a document is held to. A memory document is instructions from the organisation that every session in its scope reads, before the person's own and the repository's, read-only to agents.",
      risk: :read,
      arguments: []
    },
    %Method{
      name: "admin.memory.get",
      function: :memory_get,
      summary:
        "One memory document: a version's text (the one in force where no version is named), every version with who saved it and when, and what the version shown changed against the one before it, line by line (op same, del or add). A profile's has inherited: the documents of the profiles it extends, which its sessions read before its own, each with the profile it is from.",
      risk: :read,
      arguments: @memory_document ++
        [
          %Argument{
            name: "version",
            type: :integer,
            description: "The version to show. Absent is the one in force."
          }
        ]
    },
    %Method{
      name: "admin.memory.preview",
      function: :memory_preview,
      summary:
        "What saving a text as a memory document would do, written nowhere: the lines it changes against the version in force, its size against the limit, and which sessions read it and when. Refused as the save would be.",
      risk: :read,
      arguments: @memory_document ++ [@memory_text]
    },
    %Method{
      name: "admin.memory.put",
      function: :memory_put,
      summary:
        "Save a text as the next version of a memory document. The organisation's and a profile's are a platform admin's to change, a team's its team admins'. version names the version the text was edited from (0 for a document never saved): a save by somebody else since is refused as conflict, naming the version in force. An empty text clears the document; the same text as the one in force makes no version. Running sessions read it from their next turn, and signed-in machines within five minutes. Audited as memory.put.",
      risk: :write,
      arguments:
        @memory_document ++
          [
            @memory_text,
            %Argument{
              name: "version",
              type: :integer,
              description:
                "The version the text was edited from, as admin.memory.get answered it; 0 for a document never saved."
            }
          ]
    },
    %Method{
      name: "admin.github.get",
      function: :github_get,
      summary:
        "The plane's GitHub App: its App ID, API URL and where clones come from, the installations it may use, whether its private key is set (type, fingerprint and the OpenBao transit version, never the key), what a session's token is given, and who changed it last. configured is true once there is an App ID, a key and an installation. On a gitops plane it carries gitops: the GitHubApp resource its settings come from (github), the generation they were read at, and any problem the last pass reported.",
      risk: :read,
      arguments: []
    },
    %Method{
      name: "admin.github.put",
      function: :github_put,
      summary:
        "Change the plane's GitHub App, the one identity its pods clone with. Only the keys sent change; installations is the whole list; private_key is imported into OpenBao transit and never readable again, by anybody. Refused with the field and the reason, and nothing written, for anything that does not read. On a gitops plane app_id, api_url and installations are the GitHubApp resource's and are refused as managed_by_gitops; private_key and webhook_secret, which no repository holds, are taken.",
      risk: :write,
      arguments: [
        %Argument{
          name: "app",
          type: :object,
          required: true,
          description: "The keys to change.",
          properties: @github_properties
        }
      ]
    },
    %Method{
      name: "admin.github.check",
      function: :github_check,
      summary:
        "Test the plane's GitHub App without changing it: an App ID is set, OpenBao transit signs with its key, GitHub knows the App by the JWT that key signs, and every installation set here is one GitHub lists for it. Four named checks, each with what it found, and GitHub's slug and name for the App once GitHub has answered. With a repository, a fifth (Repository): a token for it is minted with what the App's installation may do there, the repository is read with it, and it is revoked; the answer's repository is {name, installation_id, permissions, revoked}, GitHub's list of what the token could do, and never the token.",
      risk: :read,
      arguments: [
        %Argument{
          name: "repository",
          type: :string,
          description:
            "owner/name: a repository of one of the App's installations, to mint, use and revoke a token for."
        }
      ]
    },
    %Method{
      name: "admin.github.deliveries",
      function: :github_deliveries,
      summary:
        "The deliveries the App's webhook took, newest first: GitHub's id for each (X-GitHub-Delivery), its event and action, when it came, and what the plane did with it (the runs it fired, the session it resumed, or why neither). Never a body.",
      risk: :read,
      arguments: [
        %Argument{
          name: "limit",
          type: :integer,
          required: false,
          description: "How many, newest first: 50 when absent, 200 at most."
        }
      ]
    },
    %Method{
      name: "admin.github.delete",
      function: :github_delete,
      summary:
        "Forget the plane's GitHub App: its App ID, API URL, installations, and which key version and webhook secret version are its own. A session naming a repository is refused from then on, a pod is given no token for one, and a delivery to /webhook/github is refused. The key and the secret stay in OpenBao transit, unused. Confirmed by the App ID.",
      risk: :destructive,
      confirm: "app_id",
      arguments: [
        %Argument{
          name: "app_id",
          type: :integer,
          required: true,
          description: "The App ID, typed back to confirm."
        }
      ]
    },
    %Method{
      name: "admin.identity.check",
      function: :identity_check,
      summary:
        "Test the identity configuration: provider discovery, its signing keys, the endpoints this plane was given, and whether anybody actually carries the group that grants platform admin. Four named checks, each with what it proved.",
      risk: :read,
      arguments: [
        %Argument{
          name: "group",
          type: :string,
          required: false,
          description:
            "A group to check instead of the configured one, to find out who would administer this platform before making it the setting."
        }
      ]
    },
    %Method{
      name: "admin.principals.list",
      function: :principals_list,
      summary:
        "A team's service principals: what each may use, when it was last used, whether it still works.",
      risk: :read,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."}
      ]
    },
    %Method{
      name: "admin.principal.create",
      function: :principal_create,
      summary:
        "Create a service principal for a team. Its secret is in the answer and is not stored anywhere it can be read again.",
      risk: :write,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "principal",
          type: :object,
          required: true,
          description: "What to create.",
          properties: @principal_properties
        }
      ]
    },
    %Method{
      name: "admin.principal.rotate",
      function: :principal_rotate,
      summary:
        "Mint a new secret for a principal. The old one stops working at once, so anything still using it fails until it is given the new one.",
      risk: :destructive,
      confirm: "subject",
      arguments: [
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The principal's subject."
        }
      ]
    },
    %Method{
      name: "admin.principal.disable",
      function: :principal_disable,
      summary: "Disable a principal. Its next call is refused; its sessions are kept.",
      risk: :destructive,
      confirm: "subject",
      arguments: [
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The principal's subject."
        }
      ]
    },
    %Method{
      name: "admin.person.budget",
      function: :person_budget,
      summary:
        "Set or clear a person's own monthly spend ceiling, in millionths, across every team they are in. It counts the calendar month in UTC and turns over on the 1st. 0 or absent is no ceiling.",
      risk: :write,
      arguments: [
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The person's subject, as the identity provider spells it."
        },
        %Argument{
          name: "budget_micros",
          type: :integer,
          description: "The ceiling. Absent or 0 clears it."
        }
      ]
    },
    %Method{
      name: "admin.budget.explain",
      function: :budget_explain,
      summary:
        "Every spend ceiling that applies to a person, narrowest first: which would bind, what each has left, the period its spend is counted over, and which rung set it. With a profile that has a monthly budget, that ceiling too (scope profile), after the person's: what the profile's sessions have spent this month, and set_by, the profile whose budget is in effect, itself or one it extends.",
      risk: :read,
      arguments: [
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The person's subject."
        },
        %Argument{
          name: "team",
          type: :string,
          description: "The team whose ceiling to include. Absent leaves that rung out."
        },
        %Argument{
          name: "profile",
          type: :string,
          description:
            "The worker profile whose monthly budget to include. Absent, or a profile with none, leaves that rung out."
        }
      ]
    },
    %Method{
      name: "admin.triggers.list",
      function: :triggers_list,
      summary:
        "A team's triggers: what fires them, what they run, and whether they are enabled. On a gitops plane each carries `gitops`: the Trigger resource it comes from, the generation it was read at, and any problem the last pass reported (`refused` with the reasons, or `missing`). A refused resource of the team with no trigger behind it is listed too, and a platform admin also sees those that name no team here, with team null.",
      risk: :read,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."}
      ]
    },
    %Method{
      name: "admin.trigger.put",
      function: :trigger_put,
      summary:
        "Create or update a trigger. A new webhook trigger is made with its key: the answer carries key and url once, and nothing shows the key again (a trigger on a GitHub repository needs none). Refused on a gitops plane as managed_by_gitops, switching one on or off included: there a repository holds the triggers, and a change is a commit to it.",
      risk: :write,
      arguments: [
        %Argument{
          name: "trigger",
          type: :object,
          required: true,
          description:
            "The trigger. Creating one needs principal, profile and source; putting one that exists changes only the fields sent.",
          properties: @trigger_properties
        }
      ]
    },
    %Method{
      name: "admin.trigger.delete",
      function: :trigger_delete,
      summary:
        "Remove a trigger. Its runs go with it; the sessions they created do not. Refused on a gitops plane as managed_by_gitops, except for a trigger the cluster has no resource for (reported missing).",
      risk: :destructive,
      confirm: "name",
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The trigger's name."
        }
      ]
    },
    %Method{
      name: "admin.trigger.revisions",
      function: :trigger_revisions,
      summary:
        "Every revision of a trigger, newest first: what each one said and when it was made.",
      risk: :read,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The trigger's name."
        }
      ]
    },
    %Method{
      name: "admin.trigger.run",
      function: :trigger_run,
      summary:
        "Fire a trigger now, by hand. It starts a real session and spends real money. Works on a gitops plane too.",
      risk: :write,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The trigger's name."
        }
      ]
    },
    %Method{
      name: "admin.trigger.fix",
      function: :trigger_fix,
      summary:
        "Start one run of a trigger on a GitHub repository on one of its issues, by hand: the console's fix this. The issue is read from GitHub first and must be an open issue of the trigger's repository, not a pull request; the repository must be one the team lists, and private or internal unless the profile allows public ones. Fired as manual, under the trigger's concurrency, the profile's and team's caps and the budget, with the issue given to the session fenced as data. A second call less than a minute after the first, by the same person on the same issue, is the run the first made. It starts a real session and spends real money. Works on a gitops plane too.",
      risk: :write,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The trigger's name: one on a GitHub repository."
        },
        %Argument{
          name: "issue",
          type: :string,
          required: true,
          description:
            "The issue: its number, or its link on GitHub (https://github.com/<owner>/<name>/issues/<number>), which must be on the trigger's repository."
        }
      ]
    },
    %Method{
      name: "admin.trigger.key.rotate",
      function: :trigger_key_rotate,
      summary:
        "Mint the trigger's own webhook key, replacing whatever it had. Returned once and never readable again; the old key stops working immediately. Only a webhook that names no GitHub repository has one: any other trigger is refused. Works on a gitops plane too: the key is the plane's and never in a resource.",
      risk: :write,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The trigger's name."
        }
      ]
    },
    %Method{
      name: "admin.runs.list",
      function: :runs_list,
      summary:
        "Trigger runs, newest first: one team's where a team is named, and every team you administer where none is.",
      risk: :read,
      arguments: [
        %Argument{
          name: "filter",
          type: :object,
          description: "Narrowing, all optional.",
          properties: @filter_properties
        }
      ]
    }
  ]

  @by_name Map.new(@methods, &{&1.name, &1})

  @doc "Every admin method, keyed by name."
  @spec methods() :: %{String.t() => Method.t()}
  def methods, do: @by_name

  @doc "Every admin method, in the order the table declares them."
  @spec list() :: [Method.t()]
  def list, do: @methods

  @doc "One method, or `nil`."
  @spec method(String.t()) :: Method.t() | nil
  def method(name), do: Map.get(@by_name, name)

  @doc "Whether a method name is an admin one."
  @spec admin_method?(String.t()) :: boolean()
  def admin_method?(name), do: Map.has_key?(@by_name, name)

  @doc "Dispatch one admin request."
  @spec call(String.t(), map(), Admin.actor()) :: {:ok, term()} | {:error, Error.t()}
  def call(name, params, actor) do
    case Map.fetch(@by_name, name) do
      :error -> {:error, Error.new(:method_not_found, %{method: name})}
      {:ok, method} -> invoke(method, params, actor)
    end
  end

  defp invoke(%Method{} = method, params, actor) do
    case missing(method, params) do
      [] ->
        arguments = Enum.map(Method.argument_names(method), &argument(&1, params))
        Kernel.apply(Admin, method.function, [actor | arguments])

      missing ->
        {:error, Error.new(:invalid_params, %{method: method.name, missing: missing})}
    end
  end

  # `required: true` was declared on forty arguments and enforced on none of them: a
  # missing one arrived at the context as `nil` and became whatever that function did
  # with a nil — for `admin.bundles.list`, an Ecto comparison against nil, which is an
  # ArgumentError, which is a 500 on a public endpoint. A declaration nothing reads is a
  # comment.
  #
  # The flat forms are honoured here too, because `argument/2` honours them: a client may
  # send a profile as `{"profile": {...}}` or as the params map itself, and a method whose
  # required argument is satisfied that way is not missing it.
  defp missing(%Method{} = method, params) do
    method
    |> Method.required_names()
    |> Enum.reject(&present?(&1, params))
  end

  defp present?(name, params) when name in ~w(profile principal trigger app) do
    is_map(params[name]) or map_size(Map.drop(params, ["confirm"])) > 0
  end

  defp present?("content", params), do: is_map(params["content"])
  defp present?("attrs", params), do: is_map(params["attrs"])
  defp present?("filter", params), do: is_map(params)
  defp present?(name, params), do: not is_nil(params[name])

  # `filter` and `attrs` are the two shapes a method takes a bag of options in; the rest
  # are plain values. A keyword list for the former because that is what the context
  # takes, and a context that took maps would be awkward for the CLI. A `profile`, a
  # `principal`, a `trigger` or the GitHub `app` is the whole params map when it is not
  # nested, so a client may send the object flat or under its name.
  defp argument("filter", params), do: options(params["filter"] || params)
  defp argument("attrs", params), do: params["attrs"] || %{}
  defp argument("profile", params), do: params["profile"] || params
  defp argument("principal", params), do: params["principal"] || params
  defp argument("trigger", params), do: params["trigger"] || params
  defp argument("app", params), do: params["app"] || params
  defp argument("content", params), do: params["content"] || %{}
  defp argument(name, params), do: params[name]

  # The filter's own declaration, so that the schema and what is read cannot differ.
  @known_options Enum.map(@filter_properties, & &1.name)

  defp options(params) when is_map(params) do
    for {key, value} <- params, key in @known_options, do: {String.to_existing_atom(key), value}
  end

  defp options(_params), do: []
end
