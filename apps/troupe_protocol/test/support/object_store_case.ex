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

  @doc """
  A bucket of the test's own with S3's object lock on, removed when the test ends.

  Object lock is how a real store refuses a delete on cue, and refuses it to everybody,
  its root user included: a version under a legal hold (`hold/3`) stays until the hold is
  lifted. MinIO turns it on only when a bucket is made, so the shared bucket cannot have
  it. For the plane's and the workers' suites too, which erase through the same module.
  """
  @spec locked_bucket(ObjectStore.t()) :: ObjectStore.t()
  def locked_bucket(store) do
    locked = %{store | bucket: "troupe-locked-" <> unique("t")}

    {:ok, %{status: 200}} =
      s3(locked, :put, nil, [], "", [{"x-amz-bucket-object-lock-enabled", "true"}])

    ExUnit.Callbacks.on_exit(fn -> drop_bucket(locked) end)
    locked
  end

  @doc "Put a legal hold on one version, or lift it with `false`."
  @spec hold(ObjectStore.t(), %{key: String.t(), version_id: String.t()}, boolean()) :: :ok
  def hold(store, version, on? \\ true) do
    {:ok, %{status: 200}} = legal_hold(store, version, on?)
    :ok
  end

  defp legal_hold(store, %{key: key, version_id: version}, on?) do
    body =
      ~s(<LegalHold xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>) <>
        if(on?, do: "ON", else: "OFF") <> "</Status></LegalHold>"

    md5 = :md5 |> :crypto.hash(body) |> Base.encode64()

    s3(store, :put, key, [{"legal-hold", ""}, {"versionId", version}], body, [
      {"content-md5", md5}
    ])
  end

  # Every hold lifted and every version gone first: S3 removes only an empty bucket. A
  # delete marker takes no hold, so what lifting one answers is not asked.
  defp drop_bucket(store) do
    {:ok, versions} = ObjectStore.list_versions(store, "")

    for version <- versions do
      legal_hold(store, version, false)
      :ok = ObjectStore.delete(store, version.key, version_id: version.version_id)
    end

    {:ok, %{status: 204}} = s3(store, :delete, nil, [], "", [])
  end

  # Signed as `Troupe.ObjectStore` signs, for the requests it has no verb for.
  defp s3(store, method, key, query, body, headers) do
    path =
      case key do
        nil ->
          "/#{store.bucket}"

        key ->
          segments =
            Enum.map_join(
              String.split(key, "/"),
              "/",
              &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)
            )

          "/#{store.bucket}/#{segments}"
      end

    url = store.endpoint <> path <> if(query == [], do: "", else: "?" <> URI.encode_query(query))
    uri = URI.parse(store.endpoint)

    signed =
      :aws_signature.sign_v4(
        store.access_key_id,
        store.secret_access_key,
        store.region,
        "s3",
        :calendar.universal_time(),
        method |> Atom.to_string() |> String.upcase(),
        url,
        [{"host", "#{uri.host}:#{uri.port}"} | headers],
        body,
        body_digest: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower),
        uri_encode_path: false
      )

    Req.request(
      method: method,
      url: url,
      headers: Enum.map(signed, fn {name, value} -> {to_string(name), to_string(value)} end),
      body: body,
      decode_body: false,
      retry: false
    )
  end
end
