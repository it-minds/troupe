defmodule Troupe.ObjectStore do
  @moduledoc """
  S3, as much of it as Troupe needs.

  Put, get, list, delete, and delete-every-version. Signed with SigV4 by
  `:aws_signature` and carried by Req, which the rest of Troupe already uses — an S3
  client with its own opinions about retries, streaming and error shapes would be a
  second HTTP stack to reason about for four verbs.

  Versioning matters more here than it usually does. The bucket has it on, so erasure
  has to delete *every* version of an object rather than adding a delete marker over the
  top: a done item requires that nothing under an erased session's prefix decrypts
  afterwards, including prior versions.
  """

  alias Troupe.ObjectStore.Signed

  @enforce_keys [:endpoint, :bucket, :access_key_id, :secret_access_key]
  defstruct [:endpoint, :bucket, :access_key_id, :secret_access_key, region: "us-east-1"]

  @type t :: %__MODULE__{}

  @typedoc """
  Either store: one with a credential, or one that borrows signatures.

  `Troupe.Sessions.Storage` takes whichever it was handed and does not ask which, so a
  pod with a service account and a laptop with neither seal through the same code.
  """
  @type store :: t() | Signed.t()

  @doc "The store this worker was configured with."
  @spec from_env() :: t()
  def from_env do
    config = Application.get_env(:troupe_protocol, :object_store, [])

    %__MODULE__{
      endpoint: Keyword.get(config, :endpoint, "http://localhost:29000"),
      bucket: Keyword.get(config, :bucket, "troupe-sessions"),
      access_key_id: Keyword.get(config, :access_key_id, "troupe"),
      secret_access_key: Keyword.get(config, :secret_access_key, "troupe-secret"),
      region: Keyword.get(config, :region, "us-east-1")
    }
  end

  @doc "Write an object. The body is already encrypted by the time it gets here."
  @spec put(store(), String.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(store, key, body, opts \\ [])

  def put(%Signed{} = signed, key, body, opts), do: Signed.put(signed, key, body, opts)

  def put(%__MODULE__{} = store, key, body, opts) do
    headers =
      [{"content-type", Keyword.get(opts, :content_type, "application/octet-stream")}] ++
        metadata_headers(Keyword.get(opts, :metadata, %{}))

    case request(store, :put, key, [], body, headers) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, %{key: key, version_id: header(response, "x-amz-version-id"), bytes: byte_size(body)}}

      {:ok, response} ->
        {:error, {:unexpected_status, response.status, response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Read an object, or say it is not there."
  @spec get(store(), String.t(), keyword()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(store, key, opts \\ [])

  def get(%Signed{} = signed, key, opts), do: Signed.get(signed, key, opts)

  def get(%__MODULE__{} = store, key, opts) do
    case request(store, :get, key, version_query(opts), "", []) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, response} -> {:error, {:unexpected_status, response.status, response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether an object exists, without fetching it."
  @spec exists?(store(), String.t()) :: boolean()
  def exists?(%Signed{} = signed, key), do: Signed.exists?(signed, key)

  def exists?(%__MODULE__{} = store, key) do
    match?({:ok, %{status: status}} when status in 200..299, request(store, :head, key, [], "", []))
  end

  @doc """
  An object's metadata without its body.

  A rebuild reads what it can *without a key*: the `x-amz-meta-` headers a worker set
  when it sealed the segment carry the epoch, the last sequence number and the head
  hash, none of which is content. That is what lets the plane reconstruct its index
  from storage it is not allowed to decrypt.
  """
  @spec head(store(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def head(%Signed{} = signed, key), do: Signed.head(signed, key)

  def head(%__MODULE__{} = store, key) do
    case request(store, :head, key, [], "", []) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, %{key: key, bytes: content_length(response), metadata: metadata_of(response)}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, response} ->
        {:error, {:unexpected_status, response.status, response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_length(response) do
    case header(response, "content-length") do
      nil -> 0
      value -> String.to_integer(value)
    end
  end

  defp metadata_of(response) do
    response.headers
    |> Enum.flat_map(fn
      {"x-amz-meta-" <> name, [value | _]} -> [{name, value}]
      {"x-amz-meta-" <> name, value} when is_binary(value) -> [{name, value}]
      _ -> []
    end)
    |> Map.new()
  end

  @doc """
  A URL that carries its own authorisation, for a caller who has no credential.

  A laptop sealing a private session cannot hold an object-storage key, and the plane
  cannot be on the path of the bytes — it has no key for them and must keep it that way.
  A presigned URL is the shape that satisfies both: the signature authorises one method
  on one key until it expires, and it is made from a credential that never leaves the
  plane.

  `UNSIGNED-PAYLOAD` rather than a body digest, because the signer does not have the
  body — the point of the exercise is that it never will. That is what S3 and MinIO
  both expect for query-parameter authorisation, and it is why the lifetime has to be
  short: within it, the URL *is* the authorisation, for whoever holds it.
  """
  @spec presign(t(), :get | :put, String.t(), keyword()) :: String.t()
  def presign(%__MODULE__{} = store, method, key, opts \\ []) when method in [:get, :put] do
    url = store.endpoint <> build_path(store, key)

    :aws_signature.sign_v4_query_params(
      store.access_key_id,
      store.secret_access_key,
      store.region,
      "s3",
      Keyword.get(opts, :now, :calendar.universal_time()),
      method_string(method),
      url,
      ttl: Keyword.get(opts, :ttl, 300),
      body_digest: "UNSIGNED-PAYLOAD",
      uri_encode_path: false
    )
  end

  @doc """
  Every key under a prefix, following continuation tokens.

  Listing is how a rebuild finds what exists, so it has to be complete rather than a
  first page: a session whose manifest is on page two of a thousand is a session the
  rebuilt index would not have.
  """
  @spec list(store(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(%Signed{} = signed, prefix), do: Signed.list(signed, prefix)

  def list(%__MODULE__{} = store, prefix) do
    collect_keys(store, prefix, nil, [])
  end

  defp collect_keys(store, prefix, token, acc) do
    query =
      [{"list-type", "2"}, {"prefix", prefix}] ++
        if token, do: [{"continuation-token", token}], else: []

    case request(store, :get, nil, query, "", []) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        keys = extract_all(body, "Key")

        case extract(body, "NextContinuationToken") do
          nil -> {:ok, Enum.reverse(acc) ++ keys}
          next -> collect_keys(store, prefix, next, Enum.reverse(keys) ++ acc)
        end

      {:ok, response} ->
        {:error, {:unexpected_status, response.status, response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Every version of every object under a prefix, delete markers included.

  What erasure has to enumerate. In a versioned bucket a plain delete adds a marker and
  leaves the content where it was, so "delete the prefix" means this list, not the
  ordinary one. Complete rather than a first page, as `list/2` is: S3 answers at most a
  thousand versions at a time, and an erasure that read one page of a long session
  deleted those and left the rest of its ciphertext where it was.

  `page_size:` asks for fewer at a time (S3's `max-keys`), which is for tests.
  """
  @spec list_versions(t(), String.t(), keyword()) ::
          {:ok, [%{key: String.t(), version_id: String.t()}]} | {:error, term()}
  def list_versions(%__MODULE__{} = store, prefix, opts \\ []) do
    page = [{"versions", ""}, {"prefix", prefix}] ++ page_size_query(opts)
    collect_versions(store, page, [], [])
  end

  defp collect_versions(store, page, marker, acc) do
    case request(store, :get, nil, page ++ marker, "", []) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        versions = extract_versions(body)

        case next_version_marker(body) do
          nil -> {:ok, Enum.reverse(acc) ++ versions}
          {:error, _} = error -> error
          next -> collect_versions(store, page, next, Enum.reverse(versions) ++ acc)
        end

      {:ok, response} ->
        {:error, {:unexpected_status, response.status, response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The next page starts after a version of a key, not after the key: one key's versions
  # run across pages, and a key marker alone would skip the rest of them. S3 sends both
  # markers when it says the listing is cut short; one that says so and sends neither
  # would have the next request ask for this page again, so that is an error rather than
  # a loop or a listing that stops early.
  defp next_version_marker(body) do
    case {extract(body, "IsTruncated"), extract(body, "NextKeyMarker"),
          extract(body, "NextVersionIdMarker")} do
      {"true", key, version} when is_binary(key) and is_binary(version) ->
        [{"key-marker", key}, {"version-id-marker", version}]

      {"true", _, _} ->
        {:error, {:truncated_without_marker, body}}

      _ ->
        nil
    end
  end

  defp page_size_query(opts) do
    case opts[:page_size] do
      nil -> []
      size -> [{"max-keys", Integer.to_string(size)}]
    end
  end

  @doc "Delete one object, or one version of it."
  @spec delete(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(%__MODULE__{} = store, key, opts \\ []) do
    case request(store, :delete, key, version_query(opts), "", []) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, response} -> {:error, {:unexpected_status, response.status, response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The most S3's `DeleteObjects` takes in one request.
  @batch 1_000

  @typedoc """
  What a delete of many versions did not do: how many went, the versions still there, and
  the first reason one of them is.
  """
  @type not_deleted :: %{
          deleted: non_neg_integer(),
          left: [%{key: String.t(), version_id: String.t()}],
          reason: term()
        }

  @doc """
  Delete everything under a prefix, every version, and say whether it did.

  Erasure's first act on storage. What makes it final is that the session's key is
  destroyed too — this removes the ciphertext, and destroying the key removes the
  possibility of reading any copy that survives in a backup.

  Lists every version before it deletes one, with `list_versions/3`'s options, then
  deletes them a thousand to a request with S3's `DeleteObjects` (`POST ?delete`), quiet,
  so the answer names only the versions it did not delete. One request per version took
  seconds for a thousand, and a session with tens of thousands outlasted the call that
  asked for it. A store with no batch delete answers `NotImplemented`, and its versions
  go one `DELETE` at a time (Decision 804).

  `{:ok, count}` only when every version is gone; otherwise `{:error, {:not_deleted,
  %{deleted:, left:, reason:}}}`. Every answer is read, because an erasure that counted
  what it sent said a refused version was gone. A version the store says it no longer
  has is gone. One it refuses is left and the rest go on, since a hold or a policy on
  one version says nothing of the next. A request it does not answer, or fails as a
  whole, stops the deleting, and what was not sent is left too: the next request would
  fare the same, and each could take a request's whole time to say so.
  """
  @spec delete_prefix(t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, {:not_deleted, not_deleted()} | term()}
  def delete_prefix(%__MODULE__{} = store, prefix, opts \\ []) do
    with {:ok, versions} <- list_versions(store, prefix, opts) do
      versions
      |> Enum.chunk_every(@batch)
      |> delete_batches(store, :batch, %{deleted: 0, left: [], reason: nil})
    end
  end

  defp delete_batches([], _store, _how, %{left: []} = outcome), do: {:ok, outcome.deleted}

  defp delete_batches([], _store, _how, outcome),
    do: {:error, {:not_deleted, %{outcome | left: Enum.reverse(outcome.left)}}}

  defp delete_batches([batch | rest], store, how, outcome) do
    case delete_batch(store, batch, how) do
      :unsupported ->
        delete_batches([batch | rest], store, :single, outcome)

      {:ok, refused} ->
        delete_batches(rest, store, how, tally(outcome, batch, refused))

      {:stopped, refused} ->
        outcome = tally(outcome, batch, refused)
        unsent = Enum.reverse(List.flatten(rest), outcome.left)
        delete_batches([], store, how, %{outcome | left: unsent})
    end
  end

  # `refused` pairs each version of the batch that is still there with why.
  defp tally(outcome, batch, refused) do
    %{
      deleted: outcome.deleted + length(batch) - length(refused),
      left: Enum.reverse(Enum.map(refused, &elem(&1, 0)), outcome.left),
      reason: outcome.reason || Enum.find_value(refused, &elem(&1, 1))
    }
  end

  defp delete_batch(store, batch, :batch) do
    body = delete_request(batch)
    md5 = :md5 |> :crypto.hash(body) |> Base.encode64()
    headers = [{"content-type", "application/xml"}, {"content-md5", md5}]

    case request(store, :post, nil, [{"delete", ""}], body, headers) do
      {:ok, %{status: status, body: answer}} when status in 200..299 ->
        if answer =~ "<DeleteResult",
          do: {:ok, refusals(batch, answer)},
          else: stopped(batch, {:unexpected_answer, status, answer})

      {:ok, %{status: status, body: answer}} ->
        if status in [405, 501] or extract(answer, "Code") == "NotImplemented",
          do: :unsupported,
          else: stopped(batch, {:unexpected_status, status, answer})

      {:error, reason} ->
        stopped(batch, reason)
    end
  end

  defp delete_batch(store, batch, :single), do: delete_singly(batch, store, [])

  # A 4xx is about that version; anything else is about the store.
  defp delete_singly([], _store, refused), do: {:ok, Enum.reverse(refused)}

  defp delete_singly([version | rest] = unsent, store, refused) do
    case delete(store, version.key, version_id: version.version_id) do
      :ok ->
        delete_singly(rest, store, refused)

      {:error, {:unexpected_status, status, _body} = reason} when status in 400..499 ->
        delete_singly(rest, store, [{version, reason} | refused])

      {:error, reason} ->
        {:stopped, Enum.reverse(refused, Enum.map(unsent, &{&1, reason}))}
    end
  end

  defp stopped(batch, reason), do: {:stopped, Enum.map(batch, &{&1, reason})}

  defp delete_request(batch) do
    objects =
      Enum.map(batch, fn version ->
        [
          "<Object><Key>",
          escape(version.key),
          "</Key><VersionId>",
          escape(version.version_id),
          "</VersionId></Object>"
        ]
      end)

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Quiet>true</Quiet>),
      objects,
      "</Delete>"
    ])
  end

  # A quiet answer names only what it did not delete, each with S3's code. One the store
  # no longer has is gone, as a single delete's 404 is. An error naming a key and no
  # version leaves every version of that key in the batch, rather than none of them.
  defp refusals(batch, answer) do
    refused =
      for [_, entry] <- Regex.scan(~r/<Error>(.*?)<\/Error>/s, answer),
          extract(entry, "Code") not in ["NoSuchKey", "NoSuchVersion"],
          into: %{} do
        {{extract(entry, "Key"), extract(entry, "VersionId")},
         {:refused, extract(entry, "Code"), extract(entry, "Message")}}
      end

    Enum.flat_map(batch, fn version ->
      case refused[{version.key, version.version_id}] || refused[{version.key, nil}] do
        nil -> []
        reason -> [{version, reason}]
      end
    end)
  end

  # -- signing and transport --------------------------------------------------

  defp version_query(opts) do
    case opts[:version_id] do
      nil -> []
      version -> [{"versionId", version}]
    end
  end

  # The key and the query are kept apart all the way down. Appending `?versionId=…` to
  # a key and encoding the result gives a signature for a URL with a literal question
  # mark in the object name, which S3 then cannot find.
  defp request(store, method, key, query, body, headers) do
    url = store.endpoint <> build_path(store, key) <> query_string(query)
    now = :calendar.universal_time()

    # `host` has to be among the signed headers or S3 refuses the request — it is what
    # ties a signature to the endpoint it was made for, and without it a signature
    # captured against one bucket would work against another.
    headers = [{"host", host_of(store)} | headers]

    signed =
      :aws_signature.sign_v4(
        store.access_key_id,
        store.secret_access_key,
        store.region,
        "s3",
        now,
        method_string(method),
        url,
        header_list(headers),
        body,
        # S3 wants the payload hash in the signature rather than `UNSIGNED-PAYLOAD`,
        # and MinIO enforces it.
        body_digest: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
        # S3 is the service that does *not* double-encode the path, and the library's
        # default is the other way. The key is encoded once here, and signing it again
        # would produce a signature for a URL nobody is going to request.
        uri_encode_path: false
      )

    Req.request(
      method: method,
      url: url,
      headers: Enum.map(signed, fn {name, value} -> {to_string(name), to_string(value)} end),
      body: body,
      decode_body: false,
      retry: false,
      receive_timeout: 60_000
    )
  end

  # No key addresses the bucket itself, which is what listing does.
  defp build_path(store, nil), do: "/#{store.bucket}"
  defp build_path(store, key), do: "/#{store.bucket}/#{encode_key(key)}"

  defp query_string([]), do: ""
  defp query_string(query), do: "?" <> URI.encode_query(query)

  # Each segment is encoded, but the slashes that make the layout readable are not.
  defp encode_key(key) do
    key
    |> String.split("/")
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp method_string(method), do: method |> Atom.to_string() |> String.upcase()

  defp host_of(store) do
    uri = URI.parse(store.endpoint)
    if uri.port in [80, 443, nil], do: uri.host, else: "#{uri.host}:#{uri.port}"
  end

  defp header_list(headers), do: Enum.map(headers, fn {name, value} -> {name, value} end)

  defp metadata_headers(metadata) do
    Enum.map(metadata, fn {key, value} -> {"x-amz-meta-#{key}", to_string(value)} end)
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  # -- reading S3's XML -------------------------------------------------------
  #
  # Four verbs' worth of XML with no namespaces and no attributes. A parser dependency
  # for this would be a larger surface than the thing it parses.

  defp extract(xml, tag) do
    case Regex.run(~r/<#{tag}>([^<]*)<\/#{tag}>/, xml) do
      [_, value] -> unescape(value)
      _ -> nil
    end
  end

  defp extract_all(xml, tag) do
    ~r/<#{tag}>([^<]*)<\/#{tag}>/
    |> Regex.scan(xml)
    |> Enum.map(fn [_, value] -> unescape(value) end)
  end

  # S3 escapes the values it puts in XML, so an object named `a & b` comes back as
  # `a &amp; b`. Read literally, that is a key which does not exist — and deleting a key
  # which does not exist *succeeds*, so `delete_prefix/2` reported everything gone and
  # left the object exactly where it was. Erasure is the one thing here that has to be
  # exact, and this was the shape of it being quietly wrong.
  #
  # `&amp;` is decoded last, or `&amp;lt;` — which is how S3 writes the literal text
  # `&lt;` — would come back as `<`.
  defp unescape(value) do
    value
    |> then(&Regex.replace(~r/&#x([0-9A-Fa-f]+);/, &1, fn _, hex ->
      <<String.to_integer(hex, 16)::utf8>>
    end))
    |> then(&Regex.replace(~r/&#([0-9]+);/, &1, fn _, digits ->
      <<String.to_integer(digits)::utf8>>
    end))
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  # The other way, for the one request that carries keys in XML: `&` first, or the `&`
  # of every escape written before it would be escaped again.
  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp extract_versions(xml) do
    ~r/<(?:Version|DeleteMarker)>(.*?)<\/(?:Version|DeleteMarker)>/s
    |> Regex.scan(xml)
    |> Enum.flat_map(fn [_, entry] ->
      with key when is_binary(key) <- extract(entry, "Key"),
           version when is_binary(version) <- extract(entry, "VersionId") do
        [%{key: key, version_id: version}]
      else
        _ -> []
      end
    end)
  end
end
