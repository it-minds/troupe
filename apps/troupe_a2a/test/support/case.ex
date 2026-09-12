defmodule Troupe.A2A.Case do
  @moduledoc """
  A facade on a port of its own, in front of a stub plane and a fake worker.

  `async: false` throughout: the facade reads the plane's URL and its own public URL
  from the application environment, which is process-global, and the token cache is
  one table. Each test gets a fresh plane and worker and a cleared cache, so a token
  the previous test's plane minted is never presented to this one's.
  """

  use ExUnit.CaseTemplate

  alias Troupe.A2A.{FakeWorker, StubPlane}
  alias Troupe.A2A.Plane.Cache

  using do
    quote do
      import Troupe.A2A.Case

      alias Troupe.A2A.{FakeWorker, StubPlane}

      @moduletag timeout: 60_000
    end
  end

  setup do
    {:ok, plane} = start_supervised(StubPlane)
    {:ok, worker} = start_supervised({FakeWorker, test_pid: self()})
    StubPlane.put_worker(plane, FakeWorker.endpoint(worker))
    StubPlane.put_profiles(plane, [reviewer()])

    facade = [plug: Troupe.A2A.Router, scheme: :http, port: 0, ip: {127, 0, 0, 1}]
    {:ok, listener} = start_supervised({Bandit, facade ++ [startup_log: false]})

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    url = "http://127.0.0.1:#{port}"

    Cache.clear()
    Application.put_env(:troupe_a2a, :plane_url, StubPlane.url(plane))
    Application.put_env(:troupe_a2a, :public_url, url)
    Application.put_env(:troupe_a2a, :max_streams, 200)

    on_exit(fn ->
      Application.delete_env(:troupe_a2a, :plane_url)
      Application.delete_env(:troupe_a2a, :public_url)
      Application.delete_env(:troupe_a2a, :max_streams)
    end)

    %{plane: plane, worker: worker, url: url}
  end

  @doc "The profile the stub plane offers, as `profiles.list` would describe it."
  def reviewer do
    %{
      "name" => "reviewer",
      "channel" => "stable",
      "bundle_version" => 7,
      "bundle_hash" => "sha256:abc",
      "agents" => ["reviewer"],
      "skills" => [
        %{"name" => "review-checklist", "description" => "How we review a pull request"}
      ],
      "mcp_servers" => []
    }
  end

  @doc "An `Authorization` header value for one of the stub plane's principals."
  def auth(:litellm), do: "Bearer svc:acme/litellm:litellm-secret"
  def auth(:other), do: "Bearer svc:acme/other:other-secret"
  def auth(:person), do: "Bearer person:ada@example.test"
  def auth(:basic), do: "Basic " <> Base.encode64("svc:acme/litellm:litellm-secret")

  @doc "One JSON-RPC call to `/a2a/<profile>`; the decoded body and the status."
  def rpc(context, method, params, opts \\ []) do
    profile = Keyword.get(opts, :profile, "reviewer")
    who = Keyword.get(opts, :as, :litellm)

    {:ok, response} =
      Req.request(
        method: :post,
        url: "#{context.url}/a2a/#{profile}",
        json: %{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params},
        headers: [{"authorization", auth(who)}],
        decode_body: true,
        retry: false,
        receive_timeout: 30_000
      )

    {response.status, response.body}
  end

  @doc "`message/send` with one text part, optionally on a task."
  def send_text(context, text, opts \\ []) do
    message =
      %{"role" => "user", "parts" => [%{"kind" => "text", "text" => text}]}
      |> maybe_put("taskId", Keyword.get(opts, :task_id))

    params =
      %{"message" => message}
      |> maybe_put("configuration", Keyword.get(opts, :configuration))

    rpc(context, "message/send", params, opts)
  end

  @doc "A `message/stream`; the parsed events, in order."
  def stream(context, params, opts \\ []) do
    profile = Keyword.get(opts, :profile, "reviewer")
    who = Keyword.get(opts, :as, :litellm)
    method = Keyword.get(opts, :method, "message/stream")

    {:ok, response} =
      Req.request(
        method: :post,
        url: "#{context.url}/a2a/#{profile}",
        json: %{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params},
        headers: [{"authorization", auth(who)}],
        into: fn {:data, data}, {req, resp} ->
          {:cont, {req, %{resp | body: to_string(resp.body || "") <> data}}}
        end,
        retry: false,
        receive_timeout: 30_000
      )

    {response.status, response.body |> to_string() |> parse_sse()}
  end

  defp parse_sse(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      block
      |> String.split("\n")
      |> Enum.flat_map(fn
        "data: " <> json -> [Jason.decode!(json)]
        _line -> []
      end)
    end)
  end

  @doc "A durable event as the pod would push it."
  def event(seq, type, data, opts \\ []) do
    %{
      "seq" => seq,
      "prev_hash" => nil,
      "ts" => "2026-09-13T10:00:#{String.pad_leading(to_string(rem(seq, 60)), 2, "0")}.000Z",
      "actor" => %{"kind" => "system"},
      "agent" => Keyword.get(opts, :agent, ["root"]),
      "type" => type,
      "v" => 1,
      "data" => data
    }
  end

  @doc "An ephemeral event."
  def ephemeral(type, data) do
    %{"ephemeral" => true, "type" => type, "agent" => ["root"], "data" => data}
  end

  @doc "A root `llm_response` with one text block."
  def response(seq, text, stop_reason \\ "end_turn") do
    event(seq, "llm_response", %{
      "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]},
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
      "stop_reason" => stop_reason
    })
  end

  @doc "The opening of every session: created, started, and the prompt taken."
  def opening(prompt) do
    [
      event(1, "session_created", %{"profile" => "reviewer", "origin" => %{"kind" => "a2a"}}),
      event(2, "agent_started", %{"profile" => "reviewer", "mode" => "primary"}),
      event(3, "user_input", %{"source" => "user", "text" => prompt})
    ]
  end

  def sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
