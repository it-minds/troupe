# Loaded now rather than by the first test to call each one, which then waits on the read
# behind every other test's. `ClientTest`'s server waits five seconds for the client it
# starts, and on a slow disk under load the client's first call, which loads the client,
# its transport and the JSON-RPC modules, waited past them.
Code.require_file("../../troupe_core/test/support/preload.exs", __DIR__)
Troupe.Test.Preload.run()

ExUnit.start()
