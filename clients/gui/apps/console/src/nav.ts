// The console's map: four groups, Watch, Configure, Operate and Govern, instead of a flat
// list, as the design brief has them, with the two screens the plane's own console placed
// on its Policy page (the clients' versions and the organisation's document) as entries of
// their own.
//
// Every area is listed whether this console draws it yet or not. One it does not is a
// page that says what it will do and links to the same area in the plane's current
// console, which stays until this one covers what it does. An area a team admin cannot
// use is not shown to one: the brief hides what a role cannot do rather than showing it
// disabled.

export type Role = "platform_admin" | "team_admin";

export interface Area {
  id: string;
  label: string;
  /** Drawn by this console. */
  built: boolean;
  /** Shown to a team admin as well as a platform admin. */
  teamAdmin: boolean;
  /** The same area in the plane's current console, under `/admin`. */
  current: string | null;
  /** What it is for, in a sentence, for an area not built yet. */
  lead: string;
}

export interface Group {
  label: string;
  areas: Area[];
}

export const NAV: Group[] = [
  {
    label: "Watch",
    areas: [
      { id: "overview", label: "Overview", built: true, teamAdmin: true, current: "/", lead: "What needs attention, how each profile's fleet is doing, and what every team has spent against its budget." },
      { id: "sessions", label: "Sessions", built: true, teamAdmin: true, current: "/sessions", lead: "Every session's owner, team, profile, state, size and cost, and never what was said in it." },
      { id: "connections", label: "Connections", built: false, teamAdmin: false, current: "/connections", lead: "Which MCP servers each session is talking to, and which identity its calls go out as." },
      { id: "runs", label: "Runs and review", built: true, teamAdmin: true, current: "/review", lead: "Trigger runs, what fired them, how they ended and what they cost, and who has read them." },
    ],
  },
  {
    label: "Configure",
    areas: [
      { id: "profiles", label: "Worker profiles", built: true, teamAdmin: true, current: "/workers", lead: "Each kind of worker: its image, size, model, egress and MCP servers." },
      { id: "bundles", label: "Configuration bundles", built: true, teamAdmin: true, current: "/bundles", lead: "Versioned agents, skills and MCP servers that sessions pick up from a channel." },
      { id: "triggers", label: "Triggers", built: true, teamAdmin: true, current: "/triggers", lead: "Scheduled and webhook runs per team, each as a named service principal." },
      { id: "integrations", label: "Integrations", built: false, teamAdmin: false, current: "/integrations", lead: "Every external host anything dials, and which profiles share which servers." },
    ],
  },
  {
    label: "Operate",
    areas: [
      { id: "pods", label: "Workers and pods", built: false, teamAdmin: false, current: "/workers", lead: "The pods behind each profile, with their state, version, bundle, sessions and disk." },
      { id: "hosts", label: "Provisioners and hosts", built: false, teamAdmin: false, current: "/provisioners", lead: "What each provisioner guarantees, and the machines registered to run workers." },
      { id: "budgets", label: "Budgets", built: false, teamAdmin: true, current: "/budgets", lead: "Every team's spend against its ceiling, per-person caps, and which ceiling binds." },
    ],
  },
  {
    label: "Govern",
    areas: [
      { id: "teams", label: "Teams", built: true, teamAdmin: true, current: "/teams", lead: "" },
      { id: "identity", label: "Identity", built: false, teamAdmin: false, current: "/identity", lead: "Who administers the platform, the groups the identity provider sends, and the service principals." },
      { id: "signin", label: "Sign-in", built: false, teamAdmin: false, current: "/provider", lead: "The identity provider's connection and SCIM provisioning." },
      { id: "policy", label: "Policy and settings", built: false, teamAdmin: true, current: "/policy", lead: "Every platform setting, where its value came from, and the ladder it is decided on." },
      { id: "clients", label: "Client versions", built: true, teamAdmin: true, current: "/policy", lead: "" },
      { id: "organisation", label: "Organisation", built: true, teamAdmin: true, current: "/policy", lead: "" },
      { id: "audit", label: "Audit", built: true, teamAdmin: true, current: "/audit", lead: "Who changed what and when, field by field, and a check that the record is whole." },
      { id: "memory", label: "Company memory", built: false, teamAdmin: true, current: null, lead: "What the troupe remembers about the organisation, its teams and its profiles." },
    ],
  },
];

export const AREAS: Area[] = NAV.flatMap((g) => g.areas);

export function area(id: string): Area | null {
  return AREAS.find((a) => a.id === id) ?? null;
}

export function groupOf(id: string): string {
  return NAV.find((g) => g.areas.some((a) => a.id === id))?.label ?? "";
}

/** The groups and areas this role is shown. */
export function navFor(role: Role): Group[] {
  return NAV.map((g) => ({ label: g.label, areas: g.areas.filter((a) => role === "platform_admin" || a.teamAdmin) })).filter((g) => g.areas.length > 0);
}
