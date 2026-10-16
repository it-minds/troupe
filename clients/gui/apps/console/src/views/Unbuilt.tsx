// An area this console does not draw yet: what it will be for, and how it is done meanwhile.
// The plane's pages under `/admin` are its break-glass page and nothing else, so there is
// no other console to send a person to; what an area will do is done over the plane's
// admin API until it is drawn, and the page says so rather than leaving nowhere to go.

import type { JSX } from "react";
import type { Area } from "../nav";
import { href } from "../route";

export function Unbuilt({ area }: { area: Area }): JSX.Element {
  return (
    <div className="page">
      <div className="card unbuilt">
        <span className="status muted">○ Not in this console yet</span>
        <p className="lead">{area.lead}</p>
        <p>
          Until it is, it is done over the plane's admin API: with <code>troupe admin</code>, at <code>/rpc</code>, or with the admin MCP tools at{" "}
          <code>/mcp</code>, which answer the same methods to the same roles.
        </p>
        <p>
          <a href={href({ page: "overview" })}>Back to the overview</a>
        </p>
      </div>
    </div>
  );
}
