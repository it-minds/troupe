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
  alias Troupe.Remote.{Auth, Credentials, Discovery, Tokens}

  @doc "Runs the device flow against a plane and stores the refresh token."
  @spec login(String.t(), keyword()) :: non_neg_integer()
  def login(plane_url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, discovery} <- discover(plane_url, say),
         {:ok, request} <- start(discovery, say),
         {:ok, tokens} <- Auth.poll(discovery, request, opts),
         {:ok, path} <- Tokens.put_login(discovery.plane_url, discovery, tokens) do
      say.("signed in; credentials saved to #{path}#{permissions(path)}")
      identity(discovery.plane_url, say)
    else
      {:error, reason} -> fail(say, reason)
    end
  end

  @doc "Forgets a plane's credentials, or every plane's with `all: true`."
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
        case Tokens.logout(target) do
          {:ok, path} ->
            say.("signed out of #{describe(target)}; #{path} updated")
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
