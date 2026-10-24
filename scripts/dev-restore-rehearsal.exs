# The plane's half of `scripts/dev-restore-rehearsal`: what is written before the backup,
# and what is asked of the restored database and bucket afterwards. Run by that script,
# as `MIX_ENV=test mix run scripts/dev-restore-rehearsal.exs seed|check <dir>`, with
# `TROUPE_PLANE_TEST_DB` naming the rehearsal's database and `TROUPE_REHEARSAL_BUCKET` its
# bucket; never the ones the suites use.
#
# `seed` writes, through the plane's own modules, what a plane's backup has to bring back:
# audit rows on their hash chain, the organisation's memory, a session in object storage
# and its row in the index, and an object of bytes nobody could guess. It writes to
# `<dir>/fingerprint.json` what it made and how many rows each table had.
#
# `check` asks the restored database and bucket for each of them: the same rows in every
# table, the chain still verifying, the memory in force, the object's bytes, and an index
# rebuilt from the restored bucket that finds the session.

alias Troupe.ObjectStore
alias Troupe.Plane.{Audit, Index, Memory, Repo}
alias Troupe.Sessions.Storage

[mode, dir] =
  case System.argv() do
    [mode, dir] when mode in ["seed", "check"] -> [mode, dir]
    _other -> raise "usage: mix run scripts/dev-restore-rehearsal.exs seed|check <dir>"
  end

# The test environment logs every query; the rehearsal's lines are what it says itself.
Logger.configure(level: :warning)

bucket = System.fetch_env!("TROUPE_REHEARSAL_BUCKET")
object_store = Application.get_env(:troupe_protocol, :object_store, [])
Application.put_env(:troupe_protocol, :object_store, Keyword.put(object_store, :bucket, bucket))

{:ok, _} = Application.ensure_all_started(:troupe_plane)

case Repo.start_link() do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

store = ObjectStore.from_env()
fingerprint_path = Path.join(dir, "fingerprint.json")

# Every table in the plane's schema and its rows, but the migrations' own bookkeeping.
counts = fn ->
  %{rows: tables} =
    Repo.query!(
      "SELECT table_name FROM information_schema.tables " <>
        "WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name"
    )

  Map.new(tables, fn [table] ->
    %{rows: [[count]]} = Repo.query!(~s|SELECT count(*) FROM "#{table}"|)
    {table, count}
  end)
end

sha = fn bytes -> :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) end

case mode do
  "seed" ->
    actor = "rehearsal@example.test"

    for n <- 1..5 do
      {:ok, _} = Audit.record(actor, "setting.put", "rehearsal-#{n}", %{"n" => n})
    end

    text = "The restore rehearsal's organisation memory, written #{DateTime.utc_now()}."
    {:ok, %{now: memory}} = Memory.put(:organisation, text, actor, 0)

    session_id = "rehearsal-#{System.system_time(:second)}"

    {:ok, _} =
      Storage.put_manifest(store, session_id, %{
        team: "rehearsal",
        owner_subject: actor,
        profile: "dev",
        epoch: 2,
        last_seq: 17,
        head_hash: "sha256:rehearsal",
        object_bytes: 4096
      })

    bytes = :crypto.strong_rand_bytes(256 * 1024)
    {:ok, _} = ObjectStore.put(store, "rehearsal/#{session_id}/blob", bytes)

    {:ok, report} = Index.rebuild(only: [session_id])
    1 = report.rebuilt

    audit = Audit.verify()
    :ok = audit.result

    File.write!(
      fingerprint_path,
      Jason.encode!(
        %{
          "tables" => counts.(),
          "audit_checked" => audit.checked,
          "memory" => %{"version" => memory.version, "text" => text},
          "session_id" => session_id,
          "blob" => %{"key" => "rehearsal/#{session_id}/blob", "sha256" => sha.(bytes)}
        },
        pretty: true
      )
    )

    IO.puts(
      "seeded: #{audit.checked} audit rows on the chain, memory version #{memory.version}, " <>
        "session #{session_id}, a #{div(byte_size(bytes), 1024)} KiB object"
    )

  "check" ->
    seeded = fingerprint_path |> File.read!() |> Jason.decode!()
    failures = []

    now = counts.()

    differ =
      for {table, count} <- seeded["tables"], now[table] != count, do: {table, count, now[table]}

    failures =
      if differ == [],
        do: failures,
        else: ["tables whose rows differ (table, before, after): #{inspect(differ)}" | failures]

    audit = Audit.verify()

    failures =
      cond do
        audit.result != :ok ->
          ["the audit chain does not verify: #{inspect(audit.result)}" | failures]

        audit.checked != seeded["audit_checked"] ->
          ["the audit chain has #{audit.checked} rows, not #{seeded["audit_checked"]}" | failures]

        true ->
          failures
      end

    memory = Memory.current(:organisation)

    failures =
      if memory && memory.version == seeded["memory"]["version"] &&
           memory.text == seeded["memory"]["text"],
         do: failures,
         else: [
           "the organisation's memory is not the one in force before: #{inspect(memory)}"
           | failures
         ]

    failures =
      case ObjectStore.get(store, seeded["blob"]["key"]) do
        {:ok, bytes} ->
          if sha.(bytes) == seeded["blob"]["sha256"],
            do: failures,
            else: ["the object's bytes changed" | failures]

        other ->
          ["the object is not in the restored bucket: #{inspect(other)}" | failures]
      end

    failures =
      case Storage.get_manifest(store, seeded["session_id"]) do
        {:ok, %{"head_hash" => "sha256:rehearsal", "last_seq" => 17}} ->
          failures

        other ->
          ["the session's manifest is not in the restored bucket: #{inspect(other)}" | failures]
      end

    # And the index is rebuilt from the restored bucket alone, as after a database lost.
    failures =
      case Index.rebuild(only: [seeded["session_id"]]) do
        {:ok, %{found: 1, rebuilt: 1, failed: 0}} ->
          failures

        other ->
          ["the index would not rebuild from the restored bucket: #{inspect(other)}" | failures]
      end

    %{rows: rows} =
      Repo.query!("SELECT epoch, last_seq, head_hash FROM sessions WHERE id = $1", [
        seeded["session_id"]
      ])

    failures =
      if rows == [[2, 17, "sha256:rehearsal"]],
        do: failures,
        else: ["the session's row after the rebuild is #{inspect(rows)}" | failures]

    case failures do
      [] ->
        IO.puts(
          "restored: #{map_size(now)} tables with the rows they had, #{audit.checked} audit rows verifying, " <>
            "memory version #{memory.version}, the object's bytes, the session's manifest and row"
        )

      _ ->
        Enum.each(Enum.reverse(failures), &IO.puts(:stderr, "restore rehearsal: " <> &1))
        System.halt(1)
    end
end
