---
number: 1
title: Erlang/OTP 28.5 + Elixir 1.20.4-otp-28, not the OTP 29 the directory's original `mise.toml` pinned
date: 2026-09-11
status: accepted
paths:
  - clients/tui/mise.toml
gist: Erlang/OTP 28.5 + Elixir 1.20.4-otp-28, not the OTP 29 the directory's original `mise.toml` pinned
---

Burrito's prebuilt ERTS CDN has no OTP 29 builds (404) while 28.5 exists, and the spec asks for OTP 28; ExRatatui's precompiled NIF also targets ABI 2.17 (OTP 27/28).
