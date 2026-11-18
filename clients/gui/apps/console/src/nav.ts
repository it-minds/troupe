// The console's map: five groups, Oversee, Watch, Configure, Operate and Govern, instead of
// a flat list, as the design brief has them, with the two screens the plane's own console
// placed on its Policy page (the clients' versions and the organisation's document) as
// entries of their own.
//
// Oversee comes first: what the plane holds, every artifact and every memory document, a
// person's own among them for a platform admin. It is the administrator's whole view, not
// their own corner: what is a person's own is a filter on the page where everybody's of
// that kind is, Mine on Artifacts and on Sessions, their own memory on Memory, their
// clients on Client versions.
//
// Every area has a screen here. The plane's own pages under `/admin` are its break-glass
// page and nothing else, so no area here points at them. An area a team admin cannot use
// is not shown to one: the brief hides what a role cannot do rather than showing it
// disabled. Everybody the plane knows signs in; somebody who administers nothing, a member,
// is shown the four areas that hold something of their own, each showing them that alone.
//
// The plane holds this map too, in `Troupe.Plane.Admin.Console`, where every
// administrative method is placed on one of these areas; `test/coverage.test.ts` holds the
// two to the same areas.

/** A person who administers nothing is a `member`: the console is theirs too, for what is theirs. */
export type Role = "platform_admin" | "team_admin" | "member";

export interface Area {
  id: string;
  label: string;
  /** Shown to a team admin as well as a platform admin. */
  teamAdmin: boolean;
  /** Shown to a member too, for what is theirs there. */
  member?: boolean;
}

export interface Group {
  label: string;
  areas: Area[];
}

export const NAV: Group[] = [
  {
    label: "Oversee",
    areas: [
      { id: "artifacts", label: "Artifacts", teamAdmin: true, member: true },
      { id: "memory", label: "Memory", teamAdmin: true, member: true },
    ],
  },
  {
    label: "Watch",
    areas: [
      { id: "overview", label: "Overview", teamAdmin: true },
      { id: "sessions", label: "Sessions", teamAdmin: true, member: true },
      { id: "connections", label: "Connections", teamAdmin: false },
      { id: "runs", label: "Runs and review", teamAdmin: true },
    ],
  },
  {
    label: "Configure",
    areas: [
      { id: "profiles", label: "Profiles", teamAdmin: true },
      { id: "bundles", label: "Configuration bundles", teamAdmin: true },
      { id: "triggers", label: "Triggers", teamAdmin: true },
      { id: "integrations", label: "Integrations", teamAdmin: true },
    ],
  },
  {
    label: "Operate",
    areas: [
      { id: "pods", label: "Pods", teamAdmin: false },
      { id: "hosts", label: "Provisioners and hosts", teamAdmin: false },
      { id: "budgets", label: "Budgets", teamAdmin: true },
    ],
  },
  {
    label: "Govern",
    areas: [
      { id: "teams", label: "Teams", teamAdmin: true },
      { id: "identity", label: "Identity", teamAdmin: true },
      { id: "signin", label: "Sign-in", teamAdmin: false },
      { id: "policy", label: "Policy and settings", teamAdmin: true },
      { id: "clients", label: "Client versions", teamAdmin: true, member: true },
      { id: "organisation", label: "Organisation", teamAdmin: true },
      { id: "audit", label: "Audit", teamAdmin: true },
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

function shown(role: Role, a: Area): boolean {
  if (role === "platform_admin") return true;
  return role === "team_admin" ? a.teamAdmin : a.member === true;
}

/** The groups and areas this role is shown: every one for a platform admin, fewer for a team admin, a member's own four for a member. */
export function navFor(role: Role): Group[] {
  return NAV.map((g) => ({ label: g.label, areas: g.areas.filter((a) => shown(role, a)) })).filter((g) => g.areas.length > 0);
}

/** Where a role starts: an administrator at the Overview, a member at their sessions. */
export function startFor(role: Role): string {
  return role === "member" ? "sessions" : "overview";
}
