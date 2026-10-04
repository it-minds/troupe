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
  alias Troupe.Protocol
  alias Troupe.Remote.{Auth, Credentials, Discovery, RPC, Tokens}

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
  """
  @spec logout(String.t() | nil, keyword()) :: non_neg_integer()
  def logout(plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    target =
      cond do
        Keyword.get(opts, :all, false) -> :all
        is_binary(plane_url) -> Discovery.base(plane_url)
        true -> current()
      end

    case target do
      nil ->
        say.("not signed in to any plane")
        0

      target ->
        # Read before it is forgotten: who was signed in where is what the daemon is told.
        signed_in = signed_in(target)

        case Tokens.logout(target) do
          {:ok, path} ->
            say.("signed out of #{describe(target)}; #{Troupe.Paths.display(path)} updated")
            sign_out_daemon(signed_in, say)
            0

          {:error, reason} ->
            fail(say, reason)
        end
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
  # nothing, and is not started to be told so.
  defp sign_out_daemon([], _say), do: :ok

  defp sign_out_daemon(planes, say) do
    info = %{"name" => "troupe", "version" => to_string(Application.spec(:troupe, :vsn) || "dev")}

    case Protocol.Daemon.connect(spawn: false, client_info: info) do
      {:ok, client} ->
        try do
          Enum.each(planes, &sign_out_at(client, &1, say))
        after
          Protocol.Client.close(client)
        end

      {:error, :not_running} ->
        :ok

      {:error, reason} ->
        say.(
          "could not reach the daemon on this machine to take its plane token back: #{inspect(reason)}"
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
