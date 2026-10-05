---
number: 59
title: Token usage is normalised to four disjoint figures — `input_tokens`, `cache_read`, `cache_write`, `output_tokens` — and the TUI shows sent and received apart (`↑4.4k ↓3.1k`) with what the prompt cache served kept out of the headline
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Token usage is normalised to four disjoint figures — `input_tokens`, `cache_read`, `cache_write`, `output_tokens`
---

A window reporting `156.8k tok` was one number covering everything, and on an OpenAI-compatible provider almost all of it was prompt-cache reads, billed at a tenth: the number that looked alarming was mostly the cheapest tokens there are. The providers disagree about the shape, which is the real bug — Anthropic's `input_tokens` excludes both cache figures while OpenAI's `prompt_tokens` includes the cached ones, so the same conversation counted differently depending on who answered it. Each adapter now converts to the one shape, so `input_tokens + cache_read + cache_write` is the prompt length everywhere and `Provider.billed_input/1` is what was charged at close to full price. `Budget.add_usage/2` spends that rather than the total, because a long conversation re-reads its whole prompt every turn and would otherwise exhaust `max_input_tokens` on work the user is barely paying for — for an OpenAI-compatible provider this is roughly a tenfold increase in headroom, which is the direction the premature-exhaustion reports were pointing. The tile and the observer tree row carry the compact `↑ ↓` form, the activated pane's side panel a line each (`⟳ 148.0k from cache`, absent when the provider cached nothing) and the observer detail the one-line version. Nothing new is persisted: the cache keys ride in the existing `assistant_message.usage` map, and an event written before this folds as zero.
