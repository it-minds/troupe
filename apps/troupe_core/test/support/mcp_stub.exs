# A stdio MCP server for the tests: one tool, `greet`, answered from these few lines.
# Run as `elixir mcp_stub.exs`; reads newline-delimited JSON-RPC on stdin, answers on
# stdout, exits when stdin closes — which is the contract an MCP server has.

defmodule McpStub do
  def loop do
    case IO.gets("") do
      :eof -> :ok
      {:error, _} -> :ok
      line -> line |> String.trim() |> handle() |> then(fn _ -> loop() end)
    end
  end

  defp handle(""), do: :ok

  defp handle(line) do
    case decode(line) do
      {:ok, %{"id" => id, "method" => "initialize"}} ->
        reply(id, %{"protocolVersion" => "2025-06-18", "capabilities" => %{"tools" => %{}}, "serverInfo" => %{"name" => "stub", "version" => "1"}})

      {:ok, %{"id" => id, "method" => "tools/list"}} ->
        reply(id, %{
          "tools" => [
            %{
              "name" => "greet",
              "description" => "Says hello",
              "inputSchema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
            }
          ]
        })

      {:ok, %{"id" => id, "method" => "tools/call", "params" => %{"name" => "greet"} = params}} ->
        name = get_in(params, ["arguments", "name"]) || "world"

        if name == "nobody" do
          reply(id, %{"isError" => true, "content" => [%{"type" => "text", "text" => "nobody to greet"}]})
        else
          reply(id, %{"content" => [%{"type" => "text", "text" => "Hello, #{name}!"}]})
        end

      {:ok, %{"id" => id, "method" => method}} ->
        IO.puts(encode(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_601, "message" => "no such method #{method}"}}))

      _ ->
        :ok
    end
  end

  defp reply(id, result), do: IO.puts(encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))

  defp encode(term), do: term |> :json.encode() |> IO.iodata_to_binary()

  defp decode(line) do
    {:ok, :json.decode(line)}
  rescue
    _ -> :error
  end
end

McpStub.loop()
