#!/usr/bin/env python3
"""Drive a Troupe daemon through the five things a client has to be able to do.

Run by `Troupe.Gateway.PythonClientTest`, and therefore by CI, against a daemon
with the Fake provider. It is a conformance check on the protocol, not a demo:
the point is that a program outside the BEAM, using nothing but the standard
library, can initialize, see the fleet, replay a session from the beginning,
steer it, and answer an approval.

    conformance.py --socket PATH --session SESSION_ID

Prints one JSON object on stdout describing what it saw, and exits non-zero with
a message on stderr if anything did not hold.
"""

from __future__ import annotations

import argparse
import json
import sys

from troupe import Troupe, TroupeError


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--prompt", default="do the thing that needs approval")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    with Troupe.connect_unix(args.socket) as client:
        report = {
            "protocol_version": client.server_info.get("version"),
            "server": client.server_info.get("name"),
            "principal": client.principal.get("kind"),
            "scopes": client.scopes,
        }

        # 1. The fleet: every session this principal can see.
        fleet = client.call("fleet.get")
        report["fleet"] = [session["id"] for session in fleet["sessions"]]
        if args.session not in report["fleet"]:
            return fail(f"session {args.session} is not in the fleet: {report['fleet']}")

        # 2. Replay from the beginning, then follow live.
        subscription = client.subscribe("session:" + args.session, from_seq=0)
        report["head_seq"] = subscription["head_seq"]

        replayed = collect(client, args.session, count=subscription["head_seq"], timeout=args.timeout)
        seqs = [event["seq"] for event in replayed]
        if seqs != list(range(1, subscription["head_seq"] + 1)):
            return fail(f"replay was not a contiguous sequence from 1: {seqs}")
        report["replayed"] = len(replayed)

        # 3. Steer it.
        accepted = client.send_input(args.session, args.prompt)
        if not accepted.get("accepted"):
            return fail(f"input.send was not accepted: {accepted}")

        # 4. Answer the approval it blocks on.
        approval = wait_for(client, args.session, "approval_requested", args.timeout)
        if approval is None:
            return fail("no approval was ever requested")

        call_id = approval["data"]["call_id"]
        report["approval"] = {"call_id": call_id, "tool": approval["data"]["tool"]}
        client.respond_to_approval(args.session, call_id, "allow")

        # 5. And see the effect arrive as events, not as a return value.
        completed = wait_for(client, args.session, "tool_call_completed", args.timeout)
        if completed is None:
            return fail("the tool never completed after the approval")
        if not completed["data"]["ok"]:
            return fail(f"the tool failed after approval: {completed['data']}")

        report["tool"] = completed["data"]["name"]

        # The hash chain is verifiable from what a client was handed, with no
        # further trust in the server. (Checked in Elixir too; done here because a
        # third-party client must be able to do it without our code.)
        report["chain_ok"] = chain_verifies(replayed)

    json.dump(report, sys.stdout)
    sys.stdout.write("\n")
    return 0


def collect(client: Troupe, session_id: str, count: int, timeout: float) -> list:
    """The next `count` durable events for a session."""
    events = []
    for envelope in client.events(timeout=timeout):
        if "resync" in envelope or envelope.get("session_id") != session_id:
            continue
        event = envelope["event"]
        if event.get("seq") is None:
            continue
        events.append(event)
        if len(events) >= count:
            break
    return events


def wait_for(client: Troupe, session_id: str, type_: str, timeout: float):
    for envelope in client.events(timeout=timeout):
        if "resync" in envelope or envelope.get("session_id") != session_id:
            continue
        if envelope["event"].get("type") == type_:
            return envelope["event"]
    return None


def chain_verifies(events: list) -> bool:
    """Recompute `prev_hash` over canonical JSON and walk the chain.

    Canonical JSON is UTF-8 with object keys sorted by code point and no
    insignificant whitespace, over the event *without* its own `prev_hash`.
    """
    import hashlib

    previous = None
    for event in events:
        if event.get("prev_hash") != previous:
            return False
        body = {key: value for key, value in event.items() if key != "prev_hash"}
        encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        previous = "sha256:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    return True


def fail(message: str) -> int:
    print(f"conformance: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (TroupeError, TimeoutError, ConnectionError) as error:
        sys.exit(fail(str(error)))
