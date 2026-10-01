defmodule Troupe.MCP.OAuth.SignIn do
  @moduledoc """
  One person's sign-in to one MCP server, while the browser is out (Decision 741).

  Started by `Troupe.MCP.OAuth.sign_in/4` once discovery has said where the sign-in is
  done. It listens on the loopback address the redirect URI names — any free port
  unless the entry's `redirect_uri` fixes one, since a provider that registers loopback
  redirects matches them without the port (RFC 8252 §7.3) — and answers the URL for a
  client to open. The provider sends the browser back to that port with a code and the
  `state` this process made; anything else that arrives there is turned away, and an
  answer with a different `state` is not an answer to this sign-in. The code is
  redeemed with the PKCE verifier that never left this process, the tokens go to
  `Troupe.MCP.OAuth.Tokens`, every local session that waits for this server is told
  (`Troupe.Session.MCP.signed_in/1`), and the browser is told it can close the tab.

  It waits five minutes, then stops listening. A second sign-in to the same server
  replaces this one, whose tab is then stale. Nothing of the code, the verifier or the
  tokens is logged or sent anywhere but the token endpoint.
  """

  use GenServer, restart: :temporary

  alias Troupe.MCP.OAuth
  alias Troupe.MCP.OAuth.Tokens
  alias Troupe.Session.MCP, as: SessionMCP

  require Logger

  @wait_ms 5 * 60 * 1000
  @default_redirect "http://127.0.0.1/callback"

  @doc """
  Listen for the answer and say where to send the person: `%{url, redirect_uri,
  expires_at}`.
  """
  @spec start(OAuth.binding(), OAuth.plan()) :: {:ok, map()} | {:error, String.t()}
  def start(binding, plan) do
    stop_pending(binding)

    case DynamicSupervisor.start_child(Troupe.MCP.OAuth.SignIns, {__MODULE__, {binding, plan}}) do
      {:ok, pid} -> GenServer.call(pid, :started)
      {:error, {:listen, why}} -> {:error, why}
      {:error, other} -> {:error, "could not start the sign-in: #{inspect(other)}"}
    end
  end

  @doc "Whether a sign-in to this server is waiting for its browser."
  @spec pending?(OAuth.binding()) :: boolean()
  def pending?(binding), do: Troupe.Registry.whereis(key(binding)) != nil

  @spec start_link({OAuth.binding(), OAuth.plan()}) :: GenServer.on_start()
  def start_link({binding, plan}),
    do:
      GenServer.start_link(__MODULE__, {binding, plan},
        name: {:via, Registry, {Troupe.Registry, key(binding)}}
      )

  defp key(binding), do: {:mcp_sign_in, Troupe.Paths.state_dir(binding.state_dir), binding.key}

  defp stop_pending(binding, tries \\ 20) do
    case Troupe.Registry.whereis(key(binding)) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _gone -> :ok
        end

        # The registry forgets a name a moment after its process has gone.
        if tries > 0 do
          Process.sleep(25)
          stop_pending(binding, tries - 1)
        end
    end
  end

  # -- server --------------------------------------------------------------------------

  @impl GenServer
  def init({binding, plan}) do
    Process.set_label("troupe mcp sign-in #{binding.name}")

    {:ok, {host, port, path}} =
      OAuth.loopback_redirect(binding.config.redirect_uri || @default_redirect)

    case listen(host, port) do
      {:ok, listeners, bound} ->
        redirect_uri = "http://#{host}:#{bound}#{path}"
        {verifier, challenge} = OAuth.pkce_pair()
        state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        Enum.each(listeners, &acceptor(&1, self(), path))
        Process.send_after(self(), :expire, @wait_ms)

        {:ok,
         %{
           binding: binding,
           plan: plan,
           listeners: listeners,
           redirect_uri: redirect_uri,
           verifier: verifier,
           state: state,
           url: OAuth.authorize_url(plan, binding.config, redirect_uri, state, challenge),
           expires_at:
             DateTime.utc_now()
             |> DateTime.add(@wait_ms, :millisecond)
             |> DateTime.truncate(:second)
         }}

      {:error, why} ->
        {:stop, {:listen, why}}
    end
  end

  @impl GenServer
  def handle_call(:started, _from, state) do
    {:reply,
     {:ok,
      %{
        url: state.url,
        redirect_uri: state.redirect_uri,
        expires_at: DateTime.to_iso8601(state.expires_at)
      }}, state}
  end

  def handle_call({:callback, query}, _from, %{state: expected} = state) do
    name = state.binding.name

    cond do
      query["state"] != expected ->
        {:reply,
         {400,
          "This answer is for a sign-in Troupe did not start here. Start it again from Troupe."},
         state}

      is_binary(query["error"]) ->
        why = refusal(query)
        _ = Tokens.failed(state.binding, why)
        Logger.info("troupe: mcp: signing in to #{name} failed: #{why}")
        {:stop, :normal, {200, "Signing in to #{name} failed: #{why}."}, state}

      is_binary(query["code"]) ->
        {:stop, :normal, redeem(state, query["code"]), state}

      true ->
        {:reply, {400, "The answer carried no code. Start the sign-in again from Troupe."}, state}
    end
  end

  @impl GenServer
  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  # The name goes before the answer does: a GenServer runs `terminate/2` before it sends
  # the reply of a `{:stop, _, reply, _}`, while the registry lets go of a name only once
  # it hears of the exit. So a status read the moment the browser has its page sees the
  # outcome this sign-in recorded, not a sign-in still going on beside it.
  @impl GenServer
  def terminate(_reason, state) do
    Registry.unregister(Troupe.Registry, key(state.binding))
    :ok
  end

  defp redeem(state, code) do
    %{binding: binding, plan: plan} = state

    with {:ok, tokens} <-
           OAuth.exchange(plan, binding.config, code, state.verifier, state.redirect_uri),
         :ok <- Tokens.signed_in(binding, plan, tokens) do
      Logger.info("troupe: mcp: signed in to #{binding.name}")
      SessionMCP.signed_in(binding)
      as = if tokens["account"], do: " as #{tokens["account"]}", else: ""
      {200, "Signed in to #{binding.name}#{as}. You can close this tab and go back to Troupe."}
    else
      {:error, why} ->
        _ = Tokens.failed(binding, why)
        Logger.info("troupe: mcp: signing in to #{binding.name} failed: #{why}")
        {200, "Signing in to #{binding.name} failed: #{why}."}
    end
  end

  defp refusal(%{"error" => error} = query) do
    case query["error_description"] do
      why when is_binary(why) and why != "" ->
        "the authorization server refused: #{error} (#{why})"

      _none ->
        "the authorization server refused: #{error}"
    end
  end

  # -- the loopback listener -----------------------------------------------------------

  # `localhost` is listened for on both loopback addresses, since a browser may resolve
  # it to either; the second takes the port the first was given, and is skipped where
  # the machine has no IPv6 loopback.
  defp listen("localhost", port) do
    with {:ok, v4, bound} <- listen_on({127, 0, 0, 1}, [], port) do
      case listen_on({0, 0, 0, 0, 0, 0, 0, 1}, [:inet6], bound) do
        {:ok, v6, _bound} -> {:ok, [v4, v6], bound}
        {:error, _none} -> {:ok, [v4], bound}
      end
    end
  end

  defp listen("[::1]", port) do
    with {:ok, listener, bound} <- listen_on({0, 0, 0, 0, 0, 0, 0, 1}, [:inet6], port),
         do: {:ok, [listener], bound}
  end

  defp listen(_v4, port) do
    with {:ok, listener, bound} <- listen_on({127, 0, 0, 1}, [], port),
         do: {:ok, [listener], bound}
  end

  defp listen_on(ip, family, port) do
    case :gen_tcp.listen(port, family ++ [:binary, active: false, packet: :raw, ip: ip]) do
      {:ok, listener} ->
        {:ok, bound} = :inet.port(listener)
        {:ok, listener, bound}

      {:error, reason} ->
        {:error,
         "could not listen for the sign-in on port #{port}: #{:inet.format_error(reason)}"}
    end
  end

  defp acceptor(listener, parent, path), do: spawn_link(fn -> accept(listener, parent, path) end)

  defp accept(listener, parent, path) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        answer(socket, parent, path)
        accept(listener, parent, path)

      {:error, _closed} ->
        :ok
    end
  end

  defp answer(socket, parent, path) do
    {status, text} =
      case read_head(socket, "") do
        {:ok, "GET " <> rest} ->
          target = rest |> String.split(" ", parts: 2) |> hd()
          uri = URI.parse(target)

          if uri.path == path,
            do: callback(parent, URI.decode_query(uri.query || "")),
            else: {404, "Nothing here."}

        _other ->
          {400, "Nothing here."}
      end

    _ = :gen_tcp.send(socket, response(status, text))
    :gen_tcp.close(socket)
  end

  defp callback(parent, query) do
    GenServer.call(parent, {:callback, query}, 60_000)
  catch
    :exit, _gone -> {410, "This sign-in has ended. Start it again from Troupe."}
  end

  defp read_head(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        cond do
          String.contains?(acc, "\r\n\r\n") -> {:ok, acc}
          byte_size(acc) > 16_384 -> :error
          true -> read_head(socket, acc)
        end

      {:error, _reason} ->
        :error
    end
  end

  defp response(status, text) do
    body =
      "<!doctype html><meta charset=\"utf-8\"><title>Troupe</title>" <>
        "<p style=\"font-family: sans-serif\">#{escape(text)}</p>\n"

    [
      "HTTP/1.1 #{status} #{reason(status)}\r\n",
      "content-type: text/html; charset=utf-8\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "cache-control: no-store\r\n",
      "referrer-policy: no-referrer\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp reason(200), do: "OK"
  defp reason(400), do: "Bad Request"
  defp reason(404), do: "Not Found"
  defp reason(410), do: "Gone"

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
