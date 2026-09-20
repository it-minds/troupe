// Administration: views over the `admin.*` methods, and nothing else.
//
// Three rules the whole surface is built on, and each of them is a thing that could
// have gone the other way:
//
// **One public method per action.** No screen composes two calls to mean one thing. The
// plane's own table maps a method name to a function and adds nothing; four callers go
// through it — this, `troupe admin`, the MCP tools and the console — and the parity that
// makes them behave the same is only real while none of them is clever.
//
// **No session content, ever.** There is no admin method that returns any, and there is
// nothing here that would render it if there were. Administration is about profiles,
// teams, budgets and lifecycle; reading what a session said means being on its ACL.
//
// **The navigation is asked for, not inferred.** `platform_admin` is a claim; the other
// role, `team_admin`, is in no claim a client can read. So `admin.overview` is the
// probe — it is scoped to whatever the caller administers, and a person who administers
// nothing is refused, which is the question the navigation was asking.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminApi, AuthSession, FleetOverview } from "@troupe/client";
import { AdminAudit } from "./admin/Audit";
import { AdminAutomation } from "./admin/Automation";
import { AdminBundles } from "./admin/Bundles";
import { AdminFleet } from "./admin/Fleet";
import { AdminIdentity } from "./admin/Identity";
import { AdminSettings } from "./admin/Settings";
import { AdminTeams } from "./admin/Teams";

export type AdminTab = "fleet" | "bundles" | "teams" | "identity" | "automation" | "audit" | "settings";

const TABS: Array<{ id: AdminTab; label: string; platformOnly?: boolean }> = [
  { id: "fleet", label: "Fleet" },
  { id: "bundles", label: "Bundles" },
  { id: "teams", label: "Teams" },
  { id: "identity", label: "Identity" },
  { id: "automation", label: "Automation" },
  { id: "audit", label: "Audit" },
  { id: "settings", label: "Settings", platformOnly: true },
];

export function Admin({
  auth,
  api,
  platform,
  overview,
  onOpen,
}: {
  auth: AuthSession;
  api: AdminApi;
  platform: boolean;
  overview: FleetOverview | null;
  onOpen: (id: string) => void;
}): JSX.Element {
  const [tab, setTab] = useState<AdminTab>("fleet");
  const tabs = TABS.filter((t) => platform || !t.platformOnly);

  return (
    <>
      <header className="toolbar">
        <h2>Administration</h2>
        <nav className="tabs" role="tablist" aria-label="Administration">
          {tabs.map((t) => (
            <button key={t.id} role="tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)}>
              {t.label}
            </button>
          ))}
        </nav>
        <span className="spacer" />
        <span className="micro muted">{platform ? "Platform administrator" : "Team administrator"}</span>
      </header>

      <div className="listing">
        {tab === "fleet" && <AdminFleet api={api} platform={platform} overview={overview} />}
        {tab === "bundles" && <AdminBundles api={api} platform={platform} />}
        {tab === "teams" && <AdminTeams api={api} platform={platform} />}
        {tab === "identity" && <AdminIdentity api={api} platform={platform} />}
        {tab === "automation" && <AdminAutomation auth={auth} api={api} onOpen={onOpen} />}
        {tab === "audit" && <AdminAudit api={api} />}
        {tab === "settings" && platform && <AdminSettings api={api} />}
      </div>
    </>
  );
}
