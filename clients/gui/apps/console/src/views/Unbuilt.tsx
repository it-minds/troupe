// An area this console does not draw yet: what it will be for, and where it is today.
// The plane's current console stays until this one covers what it does, so every such
// area links to its page there rather than leaving a person with nowhere to go.

import type { JSX } from "react";
import type { Area } from "../nav";
import { currentConsole } from "../plane";
import { useConsole } from "../console";
import { href } from "../route";

export function Unbuilt({ area }: { area: Area }): JSX.Element {
  const { plane } = useConsole();
  return (
    <div className="page">
      <div className="card unbuilt">
        <span className="status muted">○ Not in this console yet</span>
        <p className="lead">{area.lead}</p>
        {area.current ? (
          <p>
            It is in the plane's current console, which stays until this one covers it:{" "}
            <a href={currentConsole(plane.url, area.current)}>{area.label} in the current console</a>.
          </p>
        ) : (
          <p>It is new, and not in the plane's current console either.</p>
        )}
        <p>
          <a href={href({ page: "teams" })}>Back to Teams</a>
        </p>
      </div>
    </div>
  );
}
