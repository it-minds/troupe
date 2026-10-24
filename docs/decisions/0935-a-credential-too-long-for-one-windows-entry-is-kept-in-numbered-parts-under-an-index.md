---
number: 935
title: "On Windows a credential longer than one Credential Manager entry holds is kept in numbered parts, `<target>/0` to `<target>/<n-1>`, with `<target>` holding `troupe-parts:<n>`; one that fits is one entry as before, and the desktop app and the daemon keep the same layout"
date: 2026-10-24
status: accepted
issue: 765
paths:
  - clients/gui/apps/desktop/src-tauri/src/secrets.rs
  - apps/troupe_protocol/lib/troupe/keyring/os.ex
  - apps/troupe_protocol/test/troupe/keyring_test.exs
  - clients/gui/packages/client/src/auth.ts
  - clients/gui/packages/client/test/restore.test.ts
gist: "Windows: past one entry, parts <target>/0..n-1 and <target> = troupe-parts:<n>; a value that fits (and isn't the marker) is one entry; delete takes every part"
---

D5. Windows' Credential Manager holds at most 2560 bytes in one generic credential
(`CRED_MAX_CREDENTIAL_BLOB_SIZE`). The desktop app keeps the identity provider's refresh
token through the keyring crate, which writes a password as UTF-16 and refuses one past
1280 units before writing anything; the daemon keeps its sign-in for steering (Decision
928) through `CredWriteW` from PowerShell, as UTF-8, and Windows refused one past 2560
bytes ("The stub received bad data"). Authentik's refresh tokens are 128 characters;
Entra's are opaque and have been reported past 1280 in tenants with many claims. And the
desktop wrote the token before exchanging it, without catching, so a store that refused
it failed a sign-in the provider had already answered.

- **The layout.** A value that fits one entry, and does not itself begin with
  `troupe-parts:`, is one entry under its target, exactly as every earlier release wrote
  it, so what they kept still reads. A longer one is cut into pieces that each fit, never
  inside a character, written to `<target>/0`, `<target>/1`, ... in order; then
  `<target>` is written with `troupe-parts:<n>`, their count. The index goes last, so a
  reader never finds it naming a part not yet written. A reader that finds the marker in
  `<target>` reads the `n` parts and joins them; a part missing is an error, not part of
  a token. A write that needs fewer parts than the value before it deletes the ones left
  over, and a delete reads the index first and removes every part, then the target. A
  value that begins with the marker is always kept in parts, so it reads back as itself.
- **One layout for both writers.** The desktop app's target is the crate's own
  `<key>.<service>` and its parts `<key>.<service>/<i>`; the daemon's is
  `<service>/<name>` and its parts `<service>/<name>/<i>`. Each writer keeps its encoding
  (the crate's UTF-16, the daemon's UTF-8) and cuts at that encoding's 2560 bytes, so
  parts differ in length between them; what a reader needs (the marker, the count, the
  names, the order) is the same, so one reader reads either.
- **Why parts and not UTF-8 in the crate.** `set_secret` with UTF-8 would hold 2560
  characters of an ASCII token instead of 1280, which still has a limit, and needs a read
  path telling the entries earlier releases wrote as UTF-16 from new ones. Parts have no
  limit and leave what is already there as it is.
- **Elsewhere.** The macOS keychain and the Secret Service have no such limit; a value is
  one entry there whatever its length, as before.
- **A store that refuses.** `AuthSession` catches a failed write of the refresh token,
  at a sign-in and at a renewal that rotated it: the session goes on with the plane token
  it holds, and `notKept` says in a sentence, which `console.warn` says too, that the
  next launch will ask for a sign-in again. Shown in the desktop app's own window, it is
  owed: nothing reads `notKept` there yet.
- **Proof.** The desktop crate's tests: a 4096-character value is four parts and an
  index in a store that refuses past 1280 units, reads back whole, and is deleted with
  every part; a shorter value after it takes the parts away; an entry written as before
  reads as it was; a value that looks like an index reads as itself; a part never splits
  a character; a missing part is an error. On Windows, the same 4096 characters through
  Credential Manager itself, under a service of the test's own, which it removes. The
  protocol's `KeyringTest`: on Windows, a value of 4098 bytes through `Troupe.Keyring.OS`
  is two parts of which the first is 2560 bytes, reads back whole, a short value after it
  reads as itself, and a delete leaves no part; the tip's backend refused it with "The
  stub received bad data". `restore.test.ts`: a store that refuses the token leaves the
  sign-in signed in, its session working, and `notKept` saying why.
