# sample_repo

The acceptance fixture for Troupe. `mix test` fails here on purpose:
`Inventory.below_threshold/2` uses `<` where its documented behaviour — "at or below
the reorder threshold" — calls for `<=`. The project compiles cleanly; exactly one
test fails.

    troupe run "make the tests pass" --workspace fixtures/sample_repo --headless --auto-approve

should end with the suite green.
