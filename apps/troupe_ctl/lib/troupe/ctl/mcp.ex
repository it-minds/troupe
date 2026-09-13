defmodule Troupe.Ctl.MCP do
  @moduledoc """
  `troupe mcp` — the plane's admin MCP server, reached over stdio.

  The plane serves MCP over HTTP at `/mcp` and a client that can send a bearer header can
  talk to it directly. This exists because of what that sentence costs in practice: the
  token is a *plane* token, it lasts fifteen minutes, and it is minted from a refresh token
  this binary already holds — so wiring a model to the plane without this means pasting a
  credential into a configuration file, where it will be stale by lunchtime and committed
  by Friday.

      claude mcp add troupe -- troupe mcp

  It is `troupe mcp` and not `troupe admin mcp` because `troupe admin mcp check` is already
  an admin method, and because this is not a method at all: it is the transport that carries
  every one of them.

  What travels over stdio is exactly what would travel over HTTP: this reads one JSON-RPC
  message per line, posts it, and writes the answer back as one line. Nothing is
  interpreted here — not the method, not the tool, not the arguments — because a bridge
  that understood the protocol would be a second implementation of it, and the two would
  disagree about something eventually. It is a pipe with a credential.

  ## Three rules a bridge has to get right

  **Nothing but protocol on stdout.** A stray `IO.puts` is a parse error in the client and
  a support question that looks like the server crashed. Everything this says to a person
  goes to stderr.

  **A notification has no answer.** The plane replies 202 with no body; writing anything at
  all for one — even an empty object — is a message the client never asked for and cannot
  match to a request.

  **A token is minted for a while, not for a message.** Renewing per message means a
  refresh and an exchange against the identity provider for every `tools/list` a client
  makes, and most providers rotate the refresh token on each use, so it would also be a
  credential file rewritten dozens of times a minute. The token is kept until it is nearly
  spent and renewed once.
  """

  alias Troupe.Ctl.{Credentials, Remote}

  # A plane token lasts fifteen minutes. Renewed at ten, so no request is ever made with a
  # token that could expire between here and the plane.
  @token_life_ms :timer.minutes(10)

  @doc """
  Run the bridge until stdin closes. Returns the process exit code.

  Which plane is `--plane` if one was named and the only one logged in otherwise, the same
  as every other `troupe admin` command.
  """
  @spec bridge([String.t()], keyword()) :: non_neg_integer()
  def bridge(_argv, opts \\ []) do
    case credentials(opts) do
      {:ok, plane, stored} ->
        note("troupe mcp: bridging to #{plane}")
        loop(%{plane: plane, stored: stored, opts: opts, token: nil, renew_at: 0})
        0

      {:error, message} ->
        note("troupe mcp: #{message}")
        1
    end
  end

  defp credentials(opts) do
    case Credentials.for(opts) do
      nil -> {:error, "not logged in to any plane — run `troupe login <plane-url>`"}
      %{"plane" => plane} = stored -> {:ok, plane, stored}
    end
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        note("troupe mcp: could not read stdin: #{inspect(reason)}")

      line ->
        line |> String.trim() |> forward(state) |> loop()
    end
  end

  defp forward("", state), do: state

  defp forward(line, state) do
    case Jason.decode(line) do
      {:ok, message} ->
        post(message, state)

      # Malformed input is the client's problem, and it has an id to blame it on only if we
      # can read one — which by definition we cannot. Said once, on stderr, and dropped.
      {:error, _reason} ->
        note("troupe mcp: ignoring a line that is not JSON")
        state
    end
  end

  defp post(message, state) do
    case token(state) do
      {:ok, token, state} ->
        answer(request(state.plane, token, message), message)
        state

      {:error, reason} ->
        refuse(message, reason)
        state
    end
  end

  defp request(plane, token, message) do
    Req.request(
      method: :post,
      url: plane <> "/mcp",
      json: message,
      headers: [{"authorization", "Bearer " <> token}],
      decode_body: true,
      # A tool call can be a profile write against a cluster; the default is not enough,
      # and a retry would repeat it.
      receive_timeout: 60_000,
      retry: false
    )
  end

  # 202 is the transport's answer to a notification: no body, and nothing to write back.
  defp answer({:ok, %{status: 202}}, _message), do: :ok
  defp answer({:ok, %{status: 200, body: body}}, _message) when is_map(body), do: emit(body)

  defp answer({:ok, %{status: status, body: body}}, message) do
    refuse(message, "the plane answered #{status}: #{inspect(body)}")
  end

  defp answer({:error, reason}, message) do
    refuse(message, "could not reach the plane: #{inspect(reason)}")
  end

  # A failure this side of the plane still has to reach the client as an answer to its
  # request, or the client waits for one that is never coming.
  defp refuse(%{"id" => id}, reason) when not is_nil(id) do
    emit(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_603, "message" => reason}})
  end

  defp refuse(_notification, reason), do: note("troupe mcp: #{reason}")

  defp token(%{token: token, renew_at: renew_at} = state) when is_binary(token) do
    if now() < renew_at, do: {:ok, token, state}, else: renew(state)
  end

  defp token(state), do: renew(state)

  defp renew(state) do
    case Keyword.get(state.opts, :token) || Remote.session_token(state.stored) do
      {:ok, token} ->
        {:ok, token, remember(state, token)}

      token when is_binary(token) ->
        {:ok, token, remember(state, token)}

      {:error, _reason} ->
        {:error, "the session for #{state.plane} could not be renewed — log in again"}
    end
  end

  defp remember(state, token) do
    %{state | token: token, renew_at: now() + @token_life_ms}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp emit(message), do: IO.puts(Jason.encode!(message))

  defp note(message), do: IO.puts(:stderr, message)
end
