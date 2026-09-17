defmodule Troupe.ObjectStoreCase do
  @moduledoc """
  A test that needs object storage.

  Runs against whatever `scripts/dev-up` brought up — MinIO by default — because the
  behaviour that matters is S3's: versioning, delete markers, and what a listing does
  when a prefix has a thousand keys under it. A double would agree with whatever this
  code believes rather than with S3.

  Skipped loudly when there is none.
  """

  use ExUnit.CaseTemplate

  alias Troupe.ObjectStore

  using do
    quote do
      import Troupe.ObjectStoreCase

      alias Troupe.ObjectStore
    end
  end

  setup_all do
    store = ObjectStore.from_env()

    case ObjectStore.list(store, "reachability-probe/") do
      {:ok, _} ->
        {:ok, store: store}

      {:error, reason} ->
        IO.puts(:stderr, """

        SKIPPED: no object storage (#{inspect(reason)}).
        Bring it up with `scripts/dev-up`.
        """)

        :ok
    end
  end

  setup context do
    if store = context[:store] do
      prefix = "test/" <> unique("run") <> "/"
      on_exit(fn -> ObjectStore.delete_prefix(store, prefix) end)
      %{store: store, prefix: prefix}
    else
      :ok
    end
  end

  @doc """
  A name no other run will pick, for anything that becomes an object key.

  `System.unique_integer/1` is unique within one VM and starts again in the next, so two
  runs of the same file choose the same names \u2014 and an object store is not a database.
  Nothing rolls back at the end of a test, so the second run lists what the first one wrote
  and fails about it, usually somewhere that looks nothing like the cause. CI's *ten
  consecutive runs* is exactly the shape that finds this.

  The wall clock is what makes it unique *between* runs and the counter is what makes it
  unique *within* one, so both are here.
  """
  @spec unique(String.t()) :: String.t()
  def unique(prefix) do
    "#{prefix}-#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  @doc "Fail with the reason the suite was skipped, rather than a confusing match error."
  @spec requires_store(map()) :: map()
  def requires_store(%{store: _} = context), do: context
  def requires_store(_), do: ExUnit.Assertions.flunk("no object storage; see the message from setup_all")
end
