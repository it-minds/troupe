---
number: 80
title: A plane speaks either a WebSocket or JSON-RPC over `POST`, and the client follows what discovery says
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/discovery.ex
  - clients/tui/lib/troupe/remote/plane.ex
gist: A plane speaks either a WebSocket or JSON-RPC over `POST`, and the client follows what discovery says
---

The contract describes a socket (`plane_ws`); the live deployment's `/rpc` is a POST endpoint — its own front page says "Everything a client does is JSON-RPC over `POST /rpc`", `GET /rpc` is a 404, and `POST /rpc` answers a JSON-RPC error envelope. So `plane_ws` means a socket, `plane.rpc` means POST unless it carries a `ws` scheme, and a POST endpoint that answers 404/405/426 is retried as a socket. Over POST there is nothing for a server to push on, so the fleet subscription is skipped and HQ refreshes on demand; worker connections are WebSockets either way, which is where the stream that matters lives.
