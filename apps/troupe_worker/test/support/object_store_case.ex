defmodule Troupe.Worker.ObjectStoreCase do
  @moduledoc """
  A test that needs object storage.

  Runs against whatever `scripts/dev-up` brought up — MinIO by default — because the
  behaviour that matters is S3's: versioning, delete markers, and what a listing does
  when a prefix has a thousand keys under it. A double would agree with whatever this
  code believes rather than with S3.

  Skipped loudly when there is none.
  """

  use ExUnit.CaseTemplate

  alias Troupe.Worker.ObjectStore

  using do
    quote do
      import Troupe.Worker.ObjectStoreCase

      alias Troupe.Worker.ObjectStore
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
      prefix = "test/#{System.unique_integer([:positive])}/"
      on_exit(fn -> ObjectStore.delete_prefix(store, prefix) end)
      %{store: store, prefix: prefix}
    else
      :ok
    end
  end

  @doc "Fail with the reason the suite was skipped, rather than a confusing match error."
  @spec requires_store(map()) :: map()
  def requires_store(%{store: _} = context), do: context
  def requires_store(_), do: ExUnit.Assertions.flunk("no object storage; see the message from setup_all")
end
