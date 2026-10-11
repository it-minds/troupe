defmodule Troupe.CLI.Remote do
  @moduledoc """
  `troupe login`, `troupe logout` and `troupe whoami`.

  Login runs the device flow in the foreground: the code and the URL go on
  screen first, then the poll blocks until the browser half is done. The
  refresh token lands in the config dir as a user-only file, and the command
  says so — a credential file this machine could not lock down is worth a line
  of output, not a silent success.
  """

  alias Troupe.Client
  alias Troupe.MCP.OAuth.Store
  alias Troupe.Protocol
  alias Troupe.Remote.{Auth, Credentials, Discovery, HTTP, RPC, Tokens}

  @doc "Runs the device flow against a plane and stores the refresh token."
  @spec login(String.t(), keyword()) :: non_neg_integer()
  def login(plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, discovery} <- discover(plane_url, say),
         {:ok, request} <- start(discovery, say),
         {:ok, tokens} <- Auth.poll(discovery, request, opts),
         {:ok, path} <- Tokens.put_login(discovery.plane_url, discovery, tokens) do
      say.("signed in; credentials saved to #{Troupe.Paths.display(path)}#{permissions(path)}")
      identity(discovery.plane_url, say)
    else
      {:error, reason} -> fail(say, reason)
    end
  end

  @doc """
  Forgets a plane's credentials, or every plane's with `all: true`, and has a daemon
  running here let go of the plane token it was handed for each (issue #381).

  Without a plane named, signing out of Troupe as a whole, it also signs the daemon out
  of every one of the person's own MCP servers it holds a sign-in to, each revoked at its
  provider where the provider can be told (troupe-remote Decision 872), or says why it
  could not. Naming a plane signs out of that plane alone: those sign-ins are no plane's.
  """
  @spec logout(String.t() | nil, keyword()) :: non_neg_integer()
  def logout(plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)
    all? = Keyword.get(opts, :all, false)
    servers? = all? or not is_binary(plane_url)

    target =
      cond do
        all? -> :all
        is_binary(plane_url) -> Discovery.base(plane_url)
        true -> current()
      end

    case target do
      nil ->
        say.("not signed in to any plane")
        sign_out_daemon([], servers?, say)
        0

      target ->
        # Read before it is forgotten: who was signed in where is what the daemon is told.
        signed_in = signed_in(target)

        case Tokens.logout(target) do
          {:ok, path} ->
            say.("signed out of #{describe(target)}; #{Troupe.Paths.display(path)} updated")
            sign_out_daemon(signed_in, servers?, say)
            0

          {:error, reason} ->
            fail(say, reason)
        end
    end
  end

  @doc """
  What the plane this machine is signed in to says of each component's version, for
  `troupe update` (Decision 868): `%{url: plane, versions: %{"tui" => ..., "daemon" =>
  ...}}`, or `nil` where it is signed in to none or the plane has no version policy.

  Asked with `me.client_versions`, one call on its own, not through the connection whose
  handshake a plane refuses for the very version this is meant to replace. A plane that
  cannot be asked is said in a line, and `troupe update` goes on as without one: the
  release key still decides what may be installed.
  """
  @spec client_versions(keyword()) :: map() | nil
  def client_versions(opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with url when is_binary(url) <- Keyword.get_lazy(opts, :plane_url, &current/0),
         {:ok, versions} <- versions(url) do
      %{url: url, versions: versions}
    else
      nil ->
        nil

      :none ->
        nil

      {:error, url, reason} ->
        say.(
          "could not ask #{url} which versions it serves (#{reason}); " <>
            "going on as without a plane"
        )

        nil
    end
  end

  defp versions(url) do
    request = RPC.request(1, "me.client_versions", %{})

    with {:ok, _plane} <- Tokens.load(url),
         {:ok, %{rpc_url: rpc_url}} <- Tokens.discovery(url),
         {:ok, token} <- Tokens.access_token(url),
         {:ok, %{} = versions} <- HTTP.rpc(rpc_url, token, request) do
      {:ok, versions}
    else
      # A plane from before the version policy, or one that speaks only a socket.
      {:error, %{code: -32_601}} -> :none
      {:ok, %{ws_url: _socket}} -> :none
      {:error, %{code: _code} = error} -> {:error, url, RPC.describe(error)}
      {:error, reason} -> {:error, url, inspect(reason)}
      other -> {:error, url, inspect(other)}
    end
  end

  @doc "Prints who the plane says you are, and the teams it puts you in."
  @spec whoami(String.t() | nil, keyword()) :: non_neg_integer()
  def whoami(plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    case plane_url || current() do
      nil ->
        say.("not signed in; run troupe login <plane-url>")
        1

      url ->
        identity(Discovery.base(url), say)
    end
  end

  ## Internals

  defp discover(plane_url, say) do
    case Discovery.fetch(plane_url) do
      {:ok, discovery} ->
        unless Discovery.compatible?(discovery) do
          say.(
            "warning: the plane speaks protocol #{inspect(discovery.protocol_versions)}; " <>
              "this client speaks #{Discovery.client_version()}"
          )
        end

        {:ok, discovery}

      {:error, reason} ->
        {:error, {:discovery, reason}}
    end
  end

  defp start(discovery, say) do
    case Auth.start(discovery) do
      {:ok, request} ->
        say.("")
        say.("  open #{request.verification_uri_complete || request.verification_uri}")
        say.("  and enter the code: #{request.user_code}")
        say.("")
        say.("waiting for you to finish in the browser…")
        {:ok, request}

      {:error, reason} ->
        {:error, {:device_flow, reason}}
    end
  end

  defp identity(plane_url, say) do
    with {:ok, origin} <- Client.connect_plane(plane_url),
         {:ok, me} <- Client.whoami(origin) do
      say.("#{me.name || me.sub} (#{me.sub}) on #{plane_url}")
      say.("teams: " <> teams(me.teams))
      0
    else
      {:error, reason} -> fail(say, reason)
    end
  end

  defp teams([]), do: "(none)"
  defp teams(teams), do: Enum.map_join(teams, ", ", &(&1.name || &1.id))

  defp current do
    case Credentials.fetch() do
      {:ok, %{plane_url: url}} -> url
      :error -> nil
    end
  end

  defp describe(:all), do: "every plane"
  defp describe(url), do: url

  defp signed_in(:all), do: Enum.map(Credentials.list(), &{&1.plane_url, &1.sub})

  defp signed_in(url) do
    case Credentials.fetch(url) do
      {:ok, entry} -> [{url, entry.sub}]
      :error -> []
    end
  end

  # A daemon here holds the plane token this machine's TUI or desktop app handed it, in
  # memory, and seals private sessions with it (Decision 764). Signing out takes it back
  # where it is the person's at that plane: the daemon decides, from the plane and the
  # subject it is told, and leaves somebody else's. A daemon that is not running holds
  # nothing, and is not started to be told so. The person's own MCP servers' sign-ins
  # are on disk, so a daemon that is not running is said to have kept them.
  defp sign_out_daemon([], false, _say), do: :ok

  defp sign_out_daemon(planes, servers?, say) do
    info = %{"name" => "troupe", "version" => to_string(Application.spec(:troupe, :vsn) || "dev")}

    case Protocol.Daemon.connect(spawn: false, client_info: info) do
      {:ok, client} ->
        try do
          Enum.each(planes, &sign_out_at(client, &1, say))
          if servers?, do: sign_out_servers(client, say)
        after
          Protocol.Client.close(client)
        end

      {:error, :not_running} ->
        if servers?, do: servers_kept(say, "it is not running")
        :ok

      {:error, reason} ->
        if planes != [] do
          say.(
            "could not reach the daemon on this machine to take its plane token back: #{inspect(reason)}"
          )
        end

        if servers?, do: servers_kept(say, "it could not be reached: #{inspect(reason)}")
    end
  end

  # Every one of the person's own MCP servers the daemon holds a sign-in to (Decision
  # 872): forgotten, and revoked at the provider where it can be told.
  defp sign_out_servers(client, say) do
    params = %{command_id: RPC.command_id(), all: true}

    case Protocol.Client.call(client, "mcp.sign_out", params) do
      {:ok, %{"servers" => servers}} ->
        for %{"server" => name, "revocation" => told} <- servers, told["state"] != "none" do
          say.("signed out of the MCP server #{name}; #{Client.Daemon.revocation_text(told)}")
        end

      {:ok, _answer} ->
        :ok

      {:error, error} ->
        say.("the daemon on this machine kept your sign-ins to MCP servers: #{daemon_error(error)}")
    end
  end

  # Read from the daemon's state directory, as this machine's daemon would: how many
  # sign-ins it holds, never what is in them.
  defp servers_kept(say, why) do
    held =
      nil
      |> Store.all()
      |> Enum.count(fn {_key, entry} -> is_binary(entry["access_token"]) end)

    if held > 0 do
      say.(
        "your sign-ins to #{held} MCP server(s) are kept: the daemon on this machine signs " <>
          "out of them, and #{why}; start it and run troupe logout again"
      )
    end
  end

  defp sign_out_at(client, {url, subject}, say) do
    params =
      %{command_id: RPC.command_id(), plane_url: url, subject: subject}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Protocol.Client.call(client, "identity.sign_out", params) do
      {:ok, %{"signed_out" => true}} ->
        say.(
          "the daemon on this machine no longer holds a plane token for #{url}; " <>
            "private sessions sync again once you sign in"
        )

      {:ok, _answer} ->
        :ok

      {:error, error} ->
        say.("the daemon on this machine kept its plane token for #{url}: #{daemon_error(error)}")
    end
  end

  defp daemon_error(%{message: message}) when is_binary(message), do: message
  defp daemon_error(error), do: inspect(error)

  # A file this machine could not restrict is still written — losing the login
  # would be worse — but it says so, once, where the user is looking.
  defp permissions(path) do
    if Credentials.restricted?(path),
      do: "",
      else: " (warning: could not restrict this file to your account)"
  end

  defp fail(say, {:discovery, reason}) do
    say.("could not read the plane's discovery document: #{inspect(reason)}")
    1
  end

  defp fail(say, {:device_flow, reason}) do
    say.("the device flow could not start: #{inspect(reason)}")
    1
  end

  defp fail(say, {:exchange, reason}) do
    say.(
      "signed in at the identity provider, but the plane refused the sign-in: #{inspect(reason)}"
    )

    1
  end

  defp fail(say, :logged_out) do
    say.("not signed in; run troupe login <plane-url>")
    1
  end

  defp fail(say, :access_denied) do
    say.("sign-in was refused")
    1
  end

  defp fail(say, :expired_token) do
    say.("the code expired before it was entered; run troupe login again")
    1
  end

  defp fail(say, reason)
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :timeout, :closed] do
    say.("could not reach the plane (#{reason}); check the URL and your network")
    1
  end

  defp fail(say, reason) when is_binary(reason) do
    say.(reason)
    1
  end

  defp fail(say, reason) do
    say.("failed: #{inspect(reason)}")
    1
  end
end
