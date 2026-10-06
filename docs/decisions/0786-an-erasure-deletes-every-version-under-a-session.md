---
number: 786
title: "An erasure deletes every version under a session's prefix, however many: the list it deletes from follows S3's markers to the last page"
date: 2026-10-05
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/erasure.ex
  - apps/troupe_plane/test/troupe/plane/private_erasure_test.exs
  - apps/troupe_protocol/lib/troupe/object_store.ex
  - apps/troupe_protocol/lib/troupe/sessions/storage.ex
  - apps/troupe_protocol/test/troupe/object_store_test.exs
gist: "An erasure deletes every version under a session's prefix, however many: the list it deletes from follows S3's markers to the last page"
---

D59, its first item;
Decisions 90 and 756. `ObjectStore.list_versions/2` sent one `GET ?versions&prefix=`
and returned what came back, and S3 answers at most a thousand versions at a time,
with `IsTruncated` and where the next page starts. `delete_prefix/2`, which a pod's
erasure (`Storage.erase/2`) and the plane's of a private session
(`Erasure.device_applied/2`) both go through, deleted that page and counted it as
everything: on the chunk's tip a private session with 1,040 versions kept the 40 past
the first page, a snapshot still listed under its prefix. The key was gone, so they
could not be read, but erasure is the one thing the object store has to do exactly.
- **Every page, then the deletes.** `list_versions` asks again from `NextKeyMarker`
  and `NextVersionIdMarker` while `IsTruncated` says there is more, as `list/2`
  follows its continuation token, and `delete_prefix` deletes from the whole list,
  as before. Both markers, because one key's versions run across pages and a key
  marker alone starts after the key. A page that says it was cut short and names no
  marker is an error, where asking again would get the same page and stopping would
  leave the rest. Delete markers are versions, listed and deleted as before; the
  signing, and what a failed request or delete answers, are unchanged.
- **`page_size:`**, S3's `max-keys`, on both, for a test that crosses pages with
  fourteen versions rather than a thousand. Nothing else passes it.
- **Proof:** `ObjectStoreTest`: six keys written 175 times each and a delete marker,
  1,051 versions, every one gone after `delete_prefix` (on the tip a key's oldest
  version still read back), about three seconds against the development MinIO; and
  a listing in pages of five that ends inside one key's versions, which reads five
  when the markers are not followed. The plane's `PrivateErasureTest`: a private
  session with 1,040 versions, erased and acknowledged by its daemon, has nothing
  left under its prefix and answers `objects_deleted: 1040`, failing on the tip.
