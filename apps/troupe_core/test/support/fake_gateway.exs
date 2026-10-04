# A stand-in for a LiteLLM gateway's model listings, on one loopback port, for the tests of
# model discovery (Decision 778): nothing in them may reach a real gateway. A script rather
# than a compiled support module, so the TUI's suite can `Code.require_file` it too, and so
# `elixir` can run it on its own (`serve/1`) for an installed `troupe doctor` or
# `troupe models` to be pointed at. It uses only OTP and Elixir's own `JSON`.
#
# It answers `GET /model_group/info` the way LiteLLM does, with windows and prices, and
# `GET /v1/models` with the ids alone, the way any OpenAI-compatible server does; with
# `litellm: false` the first is a 404, which is a vanilla server. A key it was not given is
# a 401 on both. Every request is recorded, so a test can say what was asked and how often.
unless Code.ensure_loaded?(Troupe.Test.FakeGateway) do
  defmodule Troupe.Test.FakeGateway do
    @key "sk-standin-0123456789"

    # The four a gateway in issue #410 served, with the windows and prices LiteLLM quotes
    # per token.
    @models [
      %{id: "gpt-oss-120b", context: 131_072, max_output: 32_768, input: 1.0e-7, output: 5.0e-7},
      %{
        id: "mistral-small-3.2",
        context: 128_000,
        max_output: 8_192,
        input: 1.0e-7,
        output: 3.0e-7
      },
      %{id: "qwen3-235b", context: 131_072, max_output: 16_384, input: 2.2e-7, output: 8.8e-7},
      %{id: "qwen3.6-35b", context: 262_144, max_output: 32_768, input: 2.0e-7, output: 8.0e-7}
    ]

    def key, do: @key
    def models, do: @models

    @doc """
    Start one. Options: `keys` (the one key above), `models` (the four above), `litellm`
    (`true`: `/model_group/info` answers) and `port` (0, any free one).
    """
    def start(opts \\ []) do
      {:ok, listener} =
        :gen_tcp.listen(Keyword.get(opts, :port, 0), [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listener)

      {:ok, agent} =
        Agent.start(fn ->
          %{
            keys: Keyword.get(opts, :keys, [@key]),
            models: Keyword.get(opts, :models, @models),
            litellm: Keyword.get(opts, :litellm, true),
            requests: []
          }
        end)

      acceptor = spawn(fn -> accept(listener, agent) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)

      url = "http://127.0.0.1:#{port}"
      %{agent: agent, listener: listener, port: port, url: url, base_url: url <> "/v1"}
    end

    def stop(fake) do
      :gen_tcp.close(fake.listener)
      if Process.alive?(fake.agent), do: Agent.stop(fake.agent)
      :ok
    end

    @doc "Change what it serves, as a gateway's operator would."
    def serve_models(fake, models), do: Agent.update(fake.agent, &%{&1 | models: models})

    @doc "Every request so far, oldest first: `%{path, authorization, status}`."
    def requests(fake), do: fake.agent |> Agent.get(& &1.requests) |> Enum.reverse()

    @doc "Run one until the VM is stopped, printing its URL and key: for an installed `troupe`."
    def serve(opts \\ []) do
      fake = start(opts)
      IO.puts("stand-in gateway at #{fake.base_url}, key #{@key}")
      Process.sleep(:infinity)
    end

    # -- the server -------------------------------------------------------------------

    defp accept(listener, agent) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          pid = spawn(fn -> handle(socket, agent) end)
          :gen_tcp.controlling_process(socket, pid)
          accept(listener, agent)

        {:error, _closed} ->
          :ok
      end
    end

    defp handle(socket, agent) do
      with {:ok, head} <- read_head(socket),
           true <- Process.alive?(agent) do
        [request_line | _] = String.split(head, "\r\n", parts: 2)
        path = request_line |> String.split(" ") |> Enum.at(1, "/") |> String.split("?") |> hd()
        authorization = header(head, "authorization")
        state = Agent.get(agent, & &1)

        {status, body} = answer(path, authorization, state)
        entry = %{path: path, authorization: authorization, status: status}
        Agent.update(agent, &%{&1 | requests: [entry | &1.requests]})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body
        )
      end

      :gen_tcp.close(socket)
    end

    defp answer(path, authorization, state) do
      cond do
        authorization not in Enum.map(state.keys, &("Bearer " <> &1)) ->
          {401, JSON.encode!(%{"error" => %{"message" => "Authentication Error, invalid key"}})}

        path == "/model_group/info" and state.litellm ->
          {200, JSON.encode!(%{"data" => Enum.map(state.models, &group/1)})}

        path == "/v1/models" ->
          data =
            Enum.map(state.models, &%{"id" => &1.id, "object" => "model", "owned_by" => "openai"})

          {200, JSON.encode!(%{"object" => "list", "data" => data})}

        true ->
          {404, JSON.encode!(%{"detail" => "Not Found"})}
      end
    end

    # LiteLLM reports token limits as floats, and the wildcard group it synthesises.
    defp group(model) do
      %{
        "model_group" => model.id,
        "mode" => "chat",
        "max_input_tokens" => model.context * 1.0,
        "max_output_tokens" => model.max_output * 1.0,
        "input_cost_per_token" => model.input,
        "output_cost_per_token" => model.output,
        "providers" => ["openai"]
      }
    end

    defp read_head(socket, buffer \\ "") do
      case String.split(buffer, "\r\n\r\n", parts: 2) do
        [head, _rest] ->
          {:ok, head}

        [_incomplete] ->
          case :gen_tcp.recv(socket, 0, 10_000) do
            {:ok, data} -> read_head(socket, buffer <> data)
            error -> error
          end
      end
    end

    defp header(head, name) do
      head
      |> String.split("\r\n")
      |> Enum.map(&String.split(&1, ":", parts: 2))
      |> Enum.find_value(fn
        [key, value] -> String.downcase(key) == name && String.trim(value)
        _line -> nil
      end)
    end
  end
end
