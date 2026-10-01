// Your own servers, offered to a session on a pod (troupe Decision 748).
//
// A server you signed in to on this computer acts as you, and its sign-in never leaves
// the daemon. A session on your team's pod can use it all the same: the app offers its
// tools to the session as tools this computer hosts, and when the agent calls one, the
// daemon makes the call with your sign-in and the answer goes back. The session asks
// before it takes them, in its own words, and this is where you answer: where the
// approval and the question panels sit, the one place on the screen a person is waited
// on. Afterwards a line says what is offered, since everyone in the session can see it.

import { useState } from "react";
import type { JSX } from "react";
import type { OfferAsk, OfferState } from "@troupe/client";
import { Pill } from "./bits";
import { Mask } from "./brand";

export function OfferPanel({ ask, onAnswer }: { ask: OfferAsk; onAnswer: (allow: boolean) => void }): JSX.Element {
  const [answered, setAnswered] = useState(false);
  const answer = (allow: boolean): void => {
    setAnswered(true);
    onAnswer(allow);
  };

  return (
    <section className="approval question" aria-label="Offer your servers">
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>Offer your servers to this session?</h2>
      </header>
      <p className="consequence">{ask.prompt}</p>
      <p className="also">
        The calls are made on this computer with your sign-in to {list(ask.servers)}. The session sees the tools, what it asks them and what
        they answer, and never your sign-in. Everyone in it can see that it uses tools on your machine.
      </p>
      <div className="answers">
        <button className="allow" onClick={() => answer(true)} disabled={answered}>
          Offer them
        </button>
        <button className="deny" onClick={() => answer(false)} disabled={answered}>
          Not now
        </button>
      </div>
    </section>
  );
}

/** What is offered, once it is, or why nothing could be. Nothing for a no or for nothing to offer. */
export function OfferLine({ offer }: { offer: OfferState }): JSX.Element | null {
  if (offer.state === "offered") {
    return (
      <div className="banner offered" role="status">
        <p>
          Your servers are offered to this session: {list(offer.servers)}, {offer.tools.length === 1 ? "1 tool" : `${offer.tools.length} tools`}.
          Their calls are made on this computer, with your sign-in.
        </p>
      </div>
    );
  }
  if (offer.state === "refused") {
    return (
      <div className="banner readonly" role="status">
        <p>Your servers could not be offered here: {offer.reason}</p>
      </div>
    );
  }
  return null;
}

function list(names: string[]): string {
  return names.length <= 1 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}
