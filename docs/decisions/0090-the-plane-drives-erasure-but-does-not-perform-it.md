---
number: 90
title: The plane drives erasure but does not perform it
date: 2026-09-11
status: accepted
paths:
  - PROTOCOL.md
gist: The plane drives erasure but does not perform it
---

It holds no credential that can
read a session key and none for object storage. A pod of the profile has both, so the
plane asks one and records which pods have complied; a pod that was offline applies
the erasure on enrol, before serving anything. The component that decides *whether*
to erase is not the component that can read what it is erasing. (390 revises the
second sentence: the plane signs object-storage URLs for a person's own sessions, and
still holds no key for what it signs for. 756 revises the first for a private session,
which has no pod: the plane destroys its key and, once the owner's daemon has stopped,
deletes its objects.)
