// What this console owes the plane's administrative surface: every `admin.*` method the
// plane serves that no screen here calls yet, the area of the map it belongs on, and where
// a person does it today. `test/coverage.test.ts` holds the console to it the way the
// plane's own `console_coverage_test` holds the LiveView console to `Admin.Console`:
//
//   * every method the plane serves (`Troupe.Plane.Admin.API`) is either called from a
//     screen here or listed below;
//   * nothing listed below is called from a screen yet, so building a screen fails the
//     test until its entry goes, and the list can only shrink;
//   * nothing is listed, or called, that the plane does not serve;
//   * what the LiveView console owes this one (`Admin.Console.owed/0`) is owed here on the
//     same area, or done.
//
// Not imported by the app: it is the console's account of itself, not part of what it
// draws.

export interface Owed {
  /** The area of the map (`nav.ts`) whose screen will call these. */
  area: string;
  /** What these are for, and where a person does them until that screen is drawn. */
  why: string;
  methods: string[];
}

export const OWED: Owed[] = [
  {
    area: "connections",
    why: "Who has connected a personal credential to which server, and whose identity a session carries; the current console's Connections page shows it.",
    methods: ["admin.connections.list"],
  },
  {
    area: "triggers",
    why: "Running a trigger by hand, and minting its webhook key behind a typed confirm; a trigger's page links to the current console's Triggers page for both.",
    methods: ["admin.trigger.run", "admin.trigger.key.rotate"],
  },
  {
    area: "integrations",
    why: "Every external host anything dials, and the plane's GitHub App, which the current console left for this one; set over /rpc or the admin MCP tools until then.",
    methods: ["admin.integrations.list", "admin.github.get", "admin.github.put"],
  },
  {
    area: "pods",
    why: "Draining a pod behind the sessions it moves, and exporting the profiles for a repository; the current console's Workers page does it.",
    methods: ["admin.pod.drain", "admin.profiles.export"],
  },
  {
    area: "hosts",
    why: "What each provisioner guarantees, and registering, rotating and switching the machines that run workers; the current console's Provisioners page does it.",
    methods: ["admin.provisioners.list", "admin.hosts.list", "admin.host.register", "admin.host.rotate", "admin.host.enabled"],
  },
  {
    area: "budgets",
    why: "A person's own spending cap and which ceiling binds them; the current console's Teams and Budgets pages do it.",
    methods: ["admin.person.budget", "admin.budget.explain"],
  },
  {
    area: "identity",
    why: "A team's service principals: made with their secret shown once, rotated and disabled; the current console's Identity page does it. A trigger's form lists them already.",
    methods: ["admin.principal.create", "admin.principal.rotate", "admin.principal.disable"],
  },
  {
    area: "identity",
    why: "People and groups that look held twice, the same email or display name under different keys, with the mismatch each most likely comes from; the Identity area's people and groups list is where it belongs, and until it is drawn it is read over /rpc or the admin MCP tools. Enabling a team already marks a group that looks held twice.",
    methods: ["admin.identity.duplicates"],
  },
  {
    area: "signin",
    why: "The identity provider's connection, tested before it is saved, and the SCIM connector's token and switch; the current console's Identity provider page does it.",
    methods: [
      "admin.provider.get",
      "admin.provider.check",
      "admin.provider.put",
      "admin.provider.reset",
      "admin.scim.get",
      "admin.scim.rotate",
      "admin.scim.delete",
      "admin.scim.update",
    ],
  },
  {
    area: "policy",
    why: "Every platform setting on the ladder, and the check that gates the admin group's; the current console's Policy page does it.",
    methods: ["admin.setting.effective", "admin.identity.check"],
  },
];
