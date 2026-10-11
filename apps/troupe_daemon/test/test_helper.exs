# The organisation's managed file and the plane's cached document (Decision 869): the
# suite's own, not this machine's, and not there.
org = Path.join(System.tmp_dir!(), "troupe-daemon-test-org-#{System.unique_integer([:positive])}")

Application.put_env(:troupe_core, :organisation,
  managed_path: Path.join(org, "managed.yaml"),
  cache_path: Path.join(org, "organisation.json")
)

ExUnit.start()
