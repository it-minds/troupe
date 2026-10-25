# Diagrams

[principles.html](principles.html) reads all sixteen in order, with a short text on the
principle behind each; it is one long page in the same design.

Standalone SVGs for presentations and web pages, drawn in the app's own design
(Afterglow, dark): the void ground, cream type, square corners, one hard shadow, the mask
for an agent and initials in a ring for a person. The colour rule is the app's too: cyan
is the machine working, amber is this machine, and pink means one thing only, *a person
must decide*.

| File | Shows |
|---|---|
| [media/01-four-layers.svg](media/01-four-layers.svg) | The onion: LLM inside an agent inside the harness inside a client, and the protocol at the harness's edge. |
| [media/02-where-the-work-runs.svg](media/02-where-the-work-runs.svg) | Three clients over one protocol; the daemon on a laptop and the worker in a pod as the same harness; what an agent calls, and which calls ask first. |
| [media/03-the-plane-and-the-pods.svg](media/03-the-plane-and-the-pods.svg) | Ask the plane, the operator spawns pods per profile, then talk to the pod directly. The daemon at home beside it, and the five images. |
| [media/04-bring-your-own.svg](media/04-bring-your-own.svg) | The harness as a puzzle piece with four sockets: client, model, tools, where it runs. One piece fitted, the alternatives beside it. |
| [media/05-actors-sessions-profiles.svg](media/05-actors-sessions-profiles.svg) | Who acts, what a session is (the log, its states), what a profile carries. |
| [media/06-one-turn.svg](media/06-one-turn.svg) | One turn of an agent: the think, act, repeat loop, streaming deltas, tool calls running at once with approval gates, and the next input as the next turn. |
| [media/07-on-the-cluster.svg](media/07-on-the-cluster.svg) | What runs where on Kubernetes: the system namespace, one namespace per profile, two ingresses, the internal control channel, and which outside services the plane and a pod each use. |
| [media/08-openbao.svg](media/08-openbao.svg) | OpenBao's three jobs: signing the plane's tokens, one key slot per session for a pod, and a person's own slots; erasure as destroying the key first. |
| [media/09-triggers.svg](media/09-triggers.svg) | Work nobody starts: a schedule, a webhook or another agent fires a trigger frozen as a revision; the session runs as a service principal with terms, and is flagged for review until a person looks. |
| [media/10-harness-habits.svg](media/10-harness-habits.svg) | Six habits of the harness: worktrees, the project brief, watch mode, bounded results, replay from the log, goal and loop. |
| [media/11-why-the-beam.svg](media/11-why-the-beam.svg) | Why Erlang: a session as its real supervision tree with the failure rules drawn on, and a ledger of what the BEAM brings against what you write by hand in Rust or Go. |
| [media/12-it-breathes.svg](media/12-it-breathes.svg) | Scaling from demand: the plane recomputes replicas every fifteen seconds and writes the WorkerProfile, the operator reconciles a StatefulSet, pods heartbeat back; one profile over one day, draining the highest ordinal first. |
| [media/13-whose-identity.svg](media/13-whose-identity.svg) | Issue 331, to speak from: a shared session where one person's tool can be driven by the others; three answers for whose identity a pod's MCP call carries (system only, on behalf of, client-hosted); the questions still open. |
| [media/14-a-profile-is-the-config.svg](media/14-a-profile-is-the-config.svg) | Where configuration lives: who writes which layer, the profile as a versioned hashed bundle under a policy ceiling, enforced by the pod and remembered by the session; against config on every laptop. |
| [media/15-agents.svg](media/15-agents.svg) | An agent is a markdown file: the frontmatter contract and the prose role; the four layers it can live in, lowest to highest; one root per session with delegation and branches; the same session.create from a person or a trigger, read from the pinned bundle on a pod. |
| [media/16-mcp-tools.svg](media/16-mcp-tools.svg) | MCP in one breath, then one pod session whose tool list holds built-ins, the bundle's servers and your laptop's tools; attach, offer with consent, discover, and a call to yours sent back over your own socket; the rules. |

Each file is 1600×900 (16:9) and scales. The first `<rect>` is the background; drop it
for a transparent page. Fonts are Figtree, DM Mono and VT323 with system fallbacks, loaded
from Google Fonts when the SVG is opened as a page; inside an `<img>` or a slide the
fallbacks apply.
