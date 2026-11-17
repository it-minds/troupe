// The console's map: four groups, Watch, Configure, Operate and Govern, instead of a flat
// list, as the design brief has them, with the two screens the plane's own console placed
// on its Policy page (the clients' versions and the organisation's document) as entries of
// their own.
//
// Every area has a screen here. The plane's own pages under `/admin` are its break-glass
// page and nothing else, so no area here points at them. An area a team admin cannot use
// is not shown to one: the brief hides what a role cannot do rather than showing it
// disabled.
//
// The plane holds this map too, in `Troupe.Plane.Admin.Console`, where every
// administrative method is placed on one of these areas; `test/coverage.test.ts` holds the
// two to the same areas.
//
// Above the four is a person's own group, of two areas: Mine, their sessions, the laptops'
// sessions offered to them and steered from here, their clients' versions and the memory
// their machines read; and Artifacts, what they, their organisation and their profiles'
// people have published. Everybody the plane knows signs in to it; an administrative role
// adds the four groups. The group is not on the plane's map, since no administrative
// method is placed on either of its areas.

/** A person who administers nothing is a `member`: the console is theirs too, for what is theirs. */
export type Role = "platform_admin" | "team_admin" | "member";

export interface Area {
  id: string;
  label: string;
  /** Shown to a team admin as well as a platform admin. */
  teamAdmin: boolean;
}

export interface Group {
  label: string;
  areas: Area[];
}

export const NAV: Group[] = [
  {
    label: "Watch",
    areas: [
      { id: "overview", label: "Overview", teamAdmin: true },
      { id: "sessions", label: "Sessions", teamAdmin: true },
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
      { id: "published", label: "Published artifacts", teamAdmin: true },
    ],
  },
  {
    label: "Govern",
    areas: [
      { id: "teams", label: "Teams", teamAdmin: true },
      { id: "identity", label: "Identity", teamAdmin: true },
      { id: "signin", label: "Sign-in", teamAdmin: false },
      { id: "policy", label: "Policy and settings", teamAdmin: true },
      { id: "clients", label: "Client versions", teamAdmin: true },
      { id: "organisation", label: "Organisation", teamAdmin: true },
      { id: "audit", label: "Audit", teamAdmin: true },
      { id: "memory", label: "Company memory", teamAdmin: true },
    ],
  },
];

/** A person's own areas, shown to every role, administrators too. */
export const MINE: Group = {
  label: "Mine",
  areas: [
    { id: "mine", label: "Mine", teamAdmin: true },
    { id: "artifacts", label: "Artifacts", teamAdmin: true },
  ],
};

export const AREAS: Area[] = [MINE, ...NAV].flatMap((g) => g.areas);

export function area(id: string): Area | null {
  return AREAS.find((a) => a.id === id) ?? null;
}

export function groupOf(id: string): string {
  return [MINE, ...NAV].find((g) => g.areas.some((a) => a.id === id))?.label ?? "";
}

/** The groups and areas this role is shown: Mine for everybody, and the administrative map for an administrator. */
export function navFor(role: Role): Group[] {
  if (role === "member") return [MINE];
  return [MINE, ...NAV.map((g) => ({ label: g.label, areas: g.areas.filter((a) => role === "platform_admin" || a.teamAdmin) })).filter((g) => g.areas.length > 0)];
}

/** Where a role starts: an administrator at the Overview, a member at what is theirs. */
export function startFor(role: Role): string {
  return role === "member" ? "mine" : "overview";
}
