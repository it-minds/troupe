// What this console owes the plane's administrative surface: every `admin.*` method the
// plane serves that no screen here calls yet, the area of the map it belongs on, and how a
// person does it until then. `test/coverage.test.ts` holds the console to it:
//
//   * every method the plane serves (`Troupe.Plane.Admin.API`) is either called from a
//     screen here or listed below;
//   * nothing listed below is called from a screen yet, so building a screen fails the
//     test until its entry goes, and the list can only shrink;
//   * nothing is listed, or called, that the plane does not serve;
//   * where the plane places a method (`Troupe.Plane.Admin.Console`), this console calls
//     it, or owes it on that same area.
//
// The plane's pages under `/admin` are its break-glass page and nothing more, so what is
// owed here is done over the admin API meanwhile: `troupe admin`, `/rpc` or the admin MCP
// tools.
//
// Not imported by the app: it is the console's account of itself, not part of what it
// draws.

export interface Owed {
  /** The area of the map (`nav.ts`) whose screen will call these. */
  area: string;
  /** What these are for, and how a person does them until that screen is drawn. */
  why: string;
  methods: string[];
}

export const OWED: Owed[] = [
  {
    area: "triggers",
    why: "Running a trigger by hand, and rotating its webhook key behind a typed confirm (a new one is minted when the trigger is made); a trigger's page names the two methods, done over the admin API until it offers them.",
    methods: ["admin.trigger.run", "admin.trigger.key.rotate"],
  },
];
