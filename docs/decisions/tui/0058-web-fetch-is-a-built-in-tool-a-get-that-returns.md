---
number: 58
title: "`web_fetch` is a built-in tool: a GET that returns a URL as text, with HTML reduced to readable text — script, style and non-content blocks dropped whole, headings keeping their level, list items a `-`, and links rendered as `text (url)` with relative hrefs resolved — and it defaults to permission `ask`"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`web_fetch` is a built-in tool: a GET that returns a URL as text, with HTML reduced to readable text"
---

Agents were working from whatever documentation happened to be in the training data or in the repository, and a link in a task description ("do it like this RFC says") was unreadable to them. It is `ask` rather than `auto` because it is the one tool that leaves the machine and the one that pulls text the user has never seen into the agent's context, which is where prompt injection would arrive; the approval preview is the URL itself, and `a` makes it one keypress for a session of documentation reading. It is in the read-only set, so `explore` and `plan` carry it — the agents that read the most and change the least. Everything is capped twice: 5 MB read off the socket (the connection is dropped past that) and 60 KB returned, because the markup around a page's text is most of its bytes. Non-text responses are refused by content type and by a UTF-8 check rather than dumped into the transcript, redirects are followed up to five, and a non-2xx status comes back as an error carrying the first 500 characters of the body, which is where an API puts the reason. The HTML reduction is a regex pass rather than a parser dependency: it is lossy by design, since the point is what the agent should read, not a faithful DOM.
