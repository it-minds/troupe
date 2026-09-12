defmodule Troupe.A2A.ArtifactsTest do
  @moduledoc """
  Artifacts: a `published` event and a blob reference become `file` parts, the route
  serves the bytes through the session's own reads, and bytes that do not match the
  hash are not served at all.
  """

  use Troupe.A2A.Case, async: false

  @review "# Review\n\nTwo findings.\n"
  @destination "team:acme/reviews/pr-812.md"

  setup context do
    hex = sha256(@review)
    finished = %{"status" => "done", "done_reason" => "finished", "last_seq" => 5}
    StubPlane.put_row(context.plane, "s-1", finished)

    FakeWorker.script(
      context.worker,
      "s-1",
      opening("Review it.") ++
        [
          event(4, "published", %{
            "source" => "session:/review.md",
            "destination" => @destination,
            "hash" => "sha256:" <> hex,
            "bytes" => byte_size(@review),
            "direction" => "out"
          }),
          response(5, "Published the review.")
        ]
    )

    FakeWorker.put_file(context.worker, "s-1", @destination, @review)
    %{hex: hex, finished: finished}
  end

  defp fetch(url, who) do
    {:ok, response} =
      Req.get(url, headers: [{"authorization", auth(who)}], retry: false, decode_body: false)

    response
  end

  test "a published file is an artifact whose URI serves the bytes", context do
    assert {200, %{"result" => task}} = rpc(context, "tasks/get", %{"id" => "s-1"})

    assert [%{"artifactId" => hex, "name" => @destination, "parts" => [part]}] =
             task["artifacts"]

    assert hex == context.hex
    assert %{"kind" => "file", "file" => %{"uri" => uri, "mimeType" => "text/markdown"}} = part
    assert uri == "#{context.url}/a2a/tasks/s-1/artifacts/#{hex}"

    response = fetch(uri, :litellm)
    assert response.status == 200
    assert response.body == @review
    assert ["text/markdown" <> _rest] = Req.Response.get_header(response, "content-type")

    # And the read went through the session's mounts, as a reader.
    assert_receive {:worker_command, "fs.read", %{"session_id" => "s-1", "path" => @destination}}
  end

  test "bytes that do not match the hash are a 502", context do
    FakeWorker.put_file(context.worker, "s-1", @destination, @review <> "tampered\n")

    response = fetch("#{context.url}/a2a/tasks/s-1/artifacts/#{context.hex}", :litellm)
    assert response.status == 502
    assert Jason.decode!(response.body)["error"] == "hash mismatch"
  end

  test "an artifact the log does not name is not found", context do
    unknown = String.duplicate("0", 64)
    response = fetch("#{context.url}/a2a/tasks/s-1/artifacts/#{unknown}", :litellm)
    assert response.status == 404
  end

  test "another principal cannot fetch it", context do
    response = fetch("#{context.url}/a2a/tasks/s-1/artifacts/#{context.hex}", :other)
    assert response.status == 404
  end

  test "a blob reference in a tool result is served from blob.get", context do
    output = String.duplicate("line\n", 5_000)
    hex = sha256(output)
    StubPlane.put_row(context.plane, "s-2", context.finished)

    blob = %{
      "blob" => "sha256:" <> hex,
      "size" => byte_size(output),
      "preview" => "line\n",
      "truncated" => true
    }

    FakeWorker.script(
      context.worker,
      "s-2",
      opening("Run it.") ++
        [
          event(4, "tool_call_completed", %{
            "call_id" => "c1",
            "name" => "shell",
            "ok" => true,
            "content" => blob
          }),
          response(5, "Ran it.")
        ]
    )

    FakeWorker.put_blob(context.worker, "s-2", "sha256:" <> hex, output)

    assert {200, %{"result" => %{"artifacts" => [artifact]}}} =
             rpc(context, "tasks/get", %{"id" => "s-2"})

    assert %{"artifactId" => ^hex, "name" => "shell result", "parts" => [part]} = artifact

    response = fetch(part["file"]["uri"], :litellm)
    assert response.status == 200
    assert response.body == output
    assert_receive {:worker_command, "blob.get", %{"session_id" => "s-2", "blob" => digest}}
    assert digest == "sha256:" <> hex
  end
end
