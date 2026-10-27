defmodule Troupe.CLI.Remote do
  @moduledoc """
  `troupe login`, `troupe logout` and `troupe whoami`.

  Login runs the device flow in the foreground: the code and the URL go on
  screen first, then the poll blocks until the browser half is done. The
  refresh token lands in the config dir as a user-only file, and the command
  says so — a credential file this machine could not lock down is worth a line
  of output, not a silent success. The file is the machine's sign-in: the
  desktop app reads it too (root Decision 958).

  Signed in, login links the daemon on this machine as the person the plane
  names and hands it the plane token, starting the installed `troupe-daemon`
  where none is running (TUI Decision 168): the installer's sign-in is then the
  daemon's as well, before any window or session has opened. A daemon linked
  to somebody else is left as it is.
  """

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.PlaneKeys
  alias Troupe.Protocol
  alias Troupe.Remote.{Auth, Credentials, Discovery, HTTP, RPC, Tokens}

  @doc """
  Runs the device flow against a plane, stores the refresh token and links the daemon
  on this machine. `daemon:` goes to `Troupe.Protocol.Daemon.connect/1`; `spawn: false`
  links a running daemon only.
  """
  @spec login(String.t(), keyword()) :: non_neg_integer()
  def login(plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, discovery} <- discover(plane_url, say),
         {:ok, request} <- start(discovery, say),
         {:ok, tokens} <- Auth.poll(discovery, request, opts),
         {:ok, path} <- Tokens.put_login(discovery.plane_url, discovery, tokens) do
      say.("signed in; credentials saved to #{Troupe.Paths.display(path)}#{permissions(path)}")
      pin(discovery.plane_url, say)
      link_daemon(discovery.plane_url, Keyword.get(opts, :daemon, []), say)
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
  ...}, release_url: url}`, or `nil` where it is signed in to none or the plane has no
  version policy.

  Taken only as the plane signed it (#657), checked against the key this machine pinned
  for the plane: one signed by another key, changed after it was signed or expired is said
  in a sentence, and the update goes on as without a plane. A plane that signs nothing is
  taken as it is, and that said in a line.

  Asked with `me.client_versions`, one call on its own, not through the connection whose
  handshake a plane refuses for the very version this is meant to replace. A plane that
  cannot be asked is said in a line, and `troupe update` goes on as without one: the
  release key still decides what may be installed.
  """
  @spec client_versions(keyword()) :: map() | nil
  def client_versions(opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with url when is_binary(url) <- Keyword.get_lazy(opts, :plane_url, &current/0),
         {:ok, answer} <- versions(url),
         {:ok, plane} <- checked(url, answer, say) do
      plane
    else
      nil ->
        nil

      :none ->
        nil

      {:refused, sentence} ->
        say.("troupe update: #{sentence}; going on as without a plane")
        nil

      {:error, url, reason} ->
        say.(
          "could not ask #{url} which versions it serves (#{reason}); " <>
            "going on as without a plane"
        )

        nil
    end
  end

  defp checked(url, answer, say) do
    case PlaneKeys.check(url, answer, "client_versions") do
      {:ok, %{"versions" => %{} = versions} = body, :signed} ->
        {:ok, %{url: url, versions: versions, release_url: release_url(body)}}

      {:ok, _body, :signed} ->
        {:refused, "the version policy #{url} signed has no versions in it"}

      {:ok, answer, :unsigned} ->
        say.(PlaneKeys.unsigned_line(url, "client_versions"))

        {:ok,
         %{url: url, versions: Map.delete(answer, "release"), release_url: release_url(answer)}}

      {:error, sentence} ->
        {:refused, sentence}
    end
  end

  defp release_url(%{"release" => %{"url" => url}}) when is_binary(url) and url != "", do: url
  defp release_url(_answer), do: nil

  @doc """
  The key a plane signs what it tells clients with, as this machine pinned it, and the one
  it offers now where that is another (#657): `troupe plane-key`.
  """
  @spec plane_key(String.t() | nil, keyword()) :: non_neg_integer()
  def plane_key(plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    case plane_url || current() do
      nil ->
        say.("not signed in; run troupe login <plane-url>")
        1

      url ->
        url = Discovery.base(url)
        served = PlaneKeys.fetch(url)
        if match?({:ok, _}, served), do: PlaneKeys.see(url, elem(served, 1))
        describe_key(url, PlaneKeys.pinned(url), served, say)
    end
  end

  defp describe_key(url, nil, :unsigned, say) do
    say.("#{url} signs nothing it tells clients (a plane from before 0.22)")
    0
  end

  defp describe_key(url, nil, {:error, why}, say) do
    say.("no key is pinned for #{url}, and its key could not be fetched: #{why}")
    1
  end

  defp describe_key(url, held, _served, say) do
    say.("#{url} signs with the key #{held["fingerprint"]}, pinned #{held["pinned_at"]}")

    case held["offered"] do
      %{"fingerprint" => offered} ->
        say.(
          "it now offers the key #{offered} instead, which is not trusted: check it with the " <>
            "plane's administrators (the console shows it), then run troupe plane-key accept #{offered}"
        )

        1

      _none ->
        0
    end
  end

  @doc """
  Accept the key a plane now signs with in place of the one pinned, by the fingerprint the
  person checked (#657): `troupe plane-key accept FINGERPRINT`.
  """
  @spec accept_plane_key(String.t(), String.t() | nil, keyword()) :: non_neg_integer()
  def accept_plane_key(fingerprint, plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with url when is_binary(url) <- plane_url || current(),
         url = Discovery.base(url),
         {:ok, served} <- served_key(url),
         {:ok, accepted} <- PlaneKeys.accept(url, fingerprint, served: served) do
      say.("the key #{accepted} is pinned for #{url}: what it signs is taken from now on")
      0
    else
      nil -> fail(say, :logged_out)
      {:error, why} -> fail(say, why)
    end
  end

  defp served_key(url) do
    case PlaneKeys.fetch(url) do
      {:ok, served} -> {:ok, served}
      :unsigned -> {:error, "#{url} signs nothing, so there is no key to accept"}
      {:error, why} -> {:error, why}
    end
  end

  # At sign-in: the key the plane signs with, pinned where none is (#657).
  defp pin(url, say) do
    with {:ok, served} <- PlaneKeys.fetch(url),
         {:ok, seen} <- PlaneKeys.see(url, served) do
      case seen do
        {:pinned, fingerprint} ->
          say.("the plane signs what it tells clients with the key #{fingerprint}; pinned")

        {:same, _fingerprint} ->
          :ok

        {:changed, pinned, offered} ->
          say.(
            "the plane now signs with the key #{offered}, not #{pinned}, the one this machine " <>
              "pinned: nothing it signs is taken until you check the new key with its " <>
              "administrators and run troupe plane-key accept #{offered}"
          )
      end
    else
      :unsigned -> say.("the plane signs nothing it tells clients (a plane from before 0.22)")
      {:error, why} -> say.("the plane's signing key was not pinned: #{why}")
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
      # A newer version the plane recommends, quietly, with what to run (Decision 874).
      if line = Client.fleet_status(origin)[:suggest], do: say.(line)
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

  # The daemon on this machine, linked as the person just signed in and handed the plane
  # token, so that private sessions and their artifacts are reachable from any client
  # from now on, not from the next `troupe` session on. A daemon linked to somebody else,
  # or to this person at another plane, is theirs and is left as it is, as `Link` leaves
  # it. Where none is running the installed `troupe-daemon` is started, as `troupe`
  # would start one; a machine with none installed is told, and `troupe` links the daemon
  # it embeds when it next opens.
  defp link_daemon(plane_url, daemon_opts, say) do
    info = %{"name" => "troupe", "version" => to_string(Application.spec(:troupe, :vsn) || "dev")}

    with {:ok, person} <- Tokens.person(plane_url),
         {:ok, client} <- Protocol.Daemon.connect([client_info: info] ++ daemon_opts) do
      try do
        link_at(client, person, plane_url, say)
      after
        Protocol.Client.close(client)
      end
    else
      {:error, :not_running} ->
        say.("no daemon is running here; troupe links the one it starts when it next opens")

      {:error, :no_daemon_command} ->
        say.(
          "no troupe-daemon is installed here; troupe links the one it starts when it next opens"
        )

      {:error, reason} ->
        say.("could not reach the daemon on this machine to link it: #{inspect(reason)}")
    end

    :ok
  end

  defp link_at(client, person, plane_url, say) do
    with {:ok, identity} <- Protocol.Client.call(client, "identity.get", %{}),
         :ok <- Link.ours(identity, person.subject, plane_url),
         {:ok, linked} <-
           Protocol.Client.call(
             client,
             "identity.link",
             Link.link_params(person, identity, plane_url)
           ) do
      say.(
        "the daemon on this machine is linked to #{linked["display_name"] || linked["subject"]} at #{plane_url}, " <>
          "and holds the plane token; private sessions started here sync"
      )
    else
      {:error, :not_ours} ->
        say.("the daemon on this machine is linked to somebody else, and was left as it is")

      {:error, :no_subject} ->
        say.("the plane named nobody to link the daemon as; it was left as it is")

      {:error, error} ->
        say.("the daemon on this machine could not be linked: #{daemon_error(error)}")
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
        Enum.each(planes, &forget_steering(&1, say))
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

  # The daemon's own sign-in for steering a session from another device (root #58) lives in
  # the operating system's credential store, so it outlasts a daemon that is not running;
  # one that started later would offer again for somebody who signed out. Taken out here,
  # where it is for this plane and person, and let go at the plane as far as it answers.
  defp forget_steering({url, subject}, say) do
    case Troupe.Keyring.Steering.forget(url, subject) do
      {:ok, sign_in} ->
        _ =
          HTTP.post_json(String.trim_trailing(sign_in.url, "/") <> "/auth/relay/release", %{
            grant: sign_in.grant
          })

        say.(
          "the daemon on this machine no longer keeps a session of yours offered at #{url}; " <>
            "its sign-in is gone from this computer's credential store"
        )

      :none ->
        :ok

      {:error, reason} ->
        say.(
          "the daemon's sign-in for steering could not be taken out of the credential store: " <>
            inspect(reason)
        )
    end
  end

  # Every one of the person's own MCP servers the daemon holds a sign-in to (Decision
  # 872): forgotten, and revoked at the provider where it can be told.
  defp sign_out_servers(client, say) do
    params = %{command_id: RPC.command_id(), all: true}

    case Protocol.Client.call(client, "mcp.sign_out", params) do
      {:ok, %{"servers" => servers}} ->
        for %{"server" => name, "revocation" => told} <- servers, told["state"] != "none" do
          say.("signed out of the MCP server #{name}; #{Client.revocation_text(told)}")
        end

      {:ok, _answer} ->
        :ok

      {:error, error} ->
        say.("the daemon on this machine kept your sign-ins to MCP servers: #{daemon_error(error)}")
    end
  end

  # Read from the daemon's state directory, where it keeps them (`mcp-oauth.json`,
  # `Troupe.MCP.OAuth.Store`): how many sign-ins it holds, never what is in them.
  defp servers_kept(say, why) do
    held =
      with {:ok, text} <- File.read(Path.join(Troupe.Paths.state_dir(), "mcp-oauth.json")),
           {:ok, %{} = entries} <- Jason.decode(text) do
        Enum.count(entries, fn {_key, entry} ->
          is_map(entry) and is_binary(entry["access_token"])
        end)
      else
        _none -> 0
      end

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
