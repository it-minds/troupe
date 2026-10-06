defmodule Troupe.ObjectStoreDeletesTest do
  @moduledoc """
  How `delete_prefix/3` sends its deletes, and what it says when they are not answered.

  Against a stand-in S3, for the answers MinIO cannot be made to give on cue: a batch
  delete failed with a 503, a connection dropped before the answer, a store with no batch
  delete. A refusal a real store makes, and the batches a real store takes, are in
  `ObjectStoreTest` and the plane's `PrivateErasureTest`.
  """

  use ExUnit.Case, async: true

  alias Troupe.ObjectStore
  alias Troupe.ObjectStoreStandIn, as: StandIn

  test "deletes go a thousand versions to a request", do: batches(2_500, [1_000, 1_000, 500])

  test "a store with no batch delete has its versions deleted one at a time" do
    versions = versions(3)

    stand_in =
      start_supervised!(
        {StandIn,
         answer(versions, fn
           %{method: "POST"} -> {501, error("NotImplemented")}
           %{method: "DELETE"} -> {204, ""}
         end)}
      )

    assert {:ok, 3} = ObjectStore.delete_prefix(StandIn.store(stand_in), "sessions/s/")

    deletes = for %{method: "DELETE"} = request <- StandIn.requests(stand_in), do: request
    assert Enum.map(deletes, & &1.query["versionId"]) == Enum.map(versions, & &1.version_id)
  end

  # D71: the answer to each delete was dropped, so a store that failed every one of them
  # was said to have deleted them all.
  test "a store that fails the delete is said to have deleted nothing" do
    stand_in =
      start_supervised!(
        {StandIn,
         answer(versions(3), fn
           %{method: method} when method in ["POST", "DELETE"] -> {503, error("SlowDown")}
         end)}
      )

    assert {:error, {:not_deleted, %{deleted: 0, left: left, reason: reason}}} =
             ObjectStore.delete_prefix(StandIn.store(stand_in), "sessions/s/")

    assert length(left) == 3
    assert {:unexpected_status, 503, _body} = reason
  end

  test "a store that hangs up before it answers is said to have deleted nothing" do
    stand_in =
      start_supervised!(
        {StandIn,
         answer(versions(3), fn
           %{method: method} when method in ["POST", "DELETE"] -> :hang_up
         end)}
      )

    assert {:error, {:not_deleted, %{deleted: 0, left: left}}} =
             ObjectStore.delete_prefix(StandIn.store(stand_in), "sessions/s/")

    assert length(left) == 3
  end

  # A batch the store fails as a whole is where it stops: the next would fare the same,
  # and each could take the whole of a request's time to say so.
  test "a failed batch stops the deleting, and what was not sent is left too" do
    stand_in =
      start_supervised!(
        {StandIn,
         answer(versions(2_500), fn
           %{method: "POST", body: body} ->
             if body =~ "v-00000000",
               do: {200, "<DeleteResult/>"},
               else: {500, error("InternalError")}
         end)}
      )

    assert {:error, {:not_deleted, %{deleted: 1_000, left: left}}} =
             ObjectStore.delete_prefix(StandIn.store(stand_in), "sessions/s/")

    assert length(left) == 1_500
    assert length(for %{method: "POST"} <- StandIn.requests(stand_in), do: :post) == 2
  end

  # What S3 says of a version that is already gone is that it is gone.
  test "a version the store no longer has counts as deleted, and one it refuses does not" do
    [gone, refused, deleted] = versions(3)

    stand_in =
      start_supervised!(
        {StandIn,
         answer([gone, refused, deleted], fn
           %{method: "POST"} ->
             {200,
              "<DeleteResult>" <>
                key_error(gone, "NoSuchVersion") <>
                key_error(refused, "AccessDenied") <> "</DeleteResult>"}
         end)}
      )

    assert {:error, {:not_deleted, %{deleted: 2, left: [left], reason: reason}}} =
             ObjectStore.delete_prefix(StandIn.store(stand_in), "sessions/s/")

    assert left.version_id == refused.version_id
    assert reason == {:refused, "AccessDenied", "Access Denied."}
  end

  # -- helpers ----------------------------------------------------------------

  defp batches(count, sizes) do
    stand_in =
      start_supervised!(
        {StandIn,
         answer(versions(count), fn
           %{method: "POST", query: %{"delete" => ""}} -> {200, "<DeleteResult/>"}
         end)}
      )

    assert {:ok, ^count} = ObjectStore.delete_prefix(StandIn.store(stand_in), "sessions/s/")

    posts = for %{method: "POST"} = request <- StandIn.requests(stand_in), do: request
    assert Enum.map(posts, &length(Regex.scan(~r/<Object>/, &1.body))) == sizes
    assert Enum.all?(posts, &(&1.body =~ "<Quiet>true</Quiet>"))
    refute Enum.any?(StandIn.requests(stand_in), &(&1.method == "DELETE"))
  end

  # The listing is always the same versions; everything else is `deletes`'s to answer.
  defp answer(versions, deletes) do
    fn
      %{method: "GET", query: %{"versions" => _}} -> {200, StandIn.listing(versions)}
      request -> deletes.(request)
    end
  end

  defp versions(count) do
    for n <- 0..(count - 1) do
      %{
        key: "sessions/s/segments/#{div(n, 10)}.seg",
        version_id: "v-" <> String.pad_leading("#{n}", 8, "0")
      }
    end
  end

  defp error(code), do: "<Error><Code>#{code}</Code><Message>#{code}</Message></Error>"

  defp key_error(version, code) do
    message =
      if code == "AccessDenied",
        do: "Access Denied.",
        else: "The specified version does not exist."

    "<Error><Key>#{version.key}</Key><VersionId>#{version.version_id}</VersionId>" <>
      "<Code>#{code}</Code><Message>#{message}</Message></Error>"
  end
end
