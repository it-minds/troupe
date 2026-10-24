// Your own servers, offered to a session on a pod (troupe Decision 748).
//
// A server you signed in to on this computer acts as you, and its sign-in never leaves
// the daemon. A session on your team's pod can use it all the same: the app offers its
// tools to the session as tools this computer hosts, and when the agent calls one, the
// daemon makes the call with your sign-in and the answer goes back. The session asks
// before it takes them, in its own words, and this is where you answer: where the
// approval and the question panels sit, the one place on the screen a person is waited
// on. Afterwards a line says what is offered, since everyone in the session can see it.
//
// With more than one server signed in, each is a box to tick, every one ticked to begin
// with but one the person left out before, and only the ticked ones are offered. A server
// signed in to while the session is open asks again, with what is offered still ticked.

import { useState } from "react";
import type { JSX } from "react";
import type { OfferAnswer, OfferAsk, OfferState } from "@troupe/client";
import { Pill } from "./bits";
import { Mask } from "./brand";

export function OfferPanel({ ask, onAnswer }: { ask: OfferAsk; onAnswer: (allow: OfferAnswer) => void }): JSX.Element {
  const [answered, setAnswered] = useState(false);
  const [ticked, setTicked] = useState<string[]>(ask.chosen ?? ask.servers);
  const answer = (allow: OfferAnswer): void => {
    setAnswered(true);
    onAnswer(allow);
  };
  const toggle = (server: string): void => setTicked((t) => (t.includes(server) ? t.filter((s) => s !== server) : [...t, server]));
  const picking = ask.servers.length > 1;
  const offering = picking ? ask.servers.filter((s) => ticked.includes(s)) : ask.servers;

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
      {picking && (
        <fieldset className="servers" aria-label="Which servers to offer">
          {ask.servers.map((server) => (
            <label key={server} className="inline">
              <input type="checkbox" checked={ticked.includes(server)} onChange={() => toggle(server)} disabled={answered} />
              {server}
              <span className="muted"> · {count(ask.tools.filter((t) => t.startsWith(`${server}.`)).length)}</span>
            </label>
          ))}
        </fieldset>
      )}
      <div className="answers">
        <button className="allow" onClick={() => answer(picking ? offering : true)} disabled={answered || offering.length === 0}>
          {picking && offering.length < ask.servers.length ? `Offer ${list(offering)}` : "Offer them"}
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

function count(tools: number): string {
  return tools === 1 ? "1 tool" : `${tools} tools`;
}

function list(names: string[]): string {
  return names.length <= 1 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}
