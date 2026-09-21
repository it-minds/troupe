defmodule Troupe.CLI.ModelConfig do
  @moduledoc """
  `troupe config pull [PLANE_URL]`: take the organisation's defaults for this machine's
  model settings from a plane and save them.

  The plane answers provider, URL, auth style and models (`me.client_defaults`) and never
  a key, so a saved key is kept and one that is missing is asked for in words. The write
  goes through the daemon's `config.set` rather than to a path computed here: the daemon
  is the process whose environment decides which `config.yaml` a session reads, and
  asking it is how this command and the desktop app's settings screen end up editing the
  same file.
  """

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol
  alias Troupe.Remote.Credentials

  @doc "Pull a plane's defaults into this machine's config; returns the exit status."
  @spec pull(String.t() | nil, (String.t() -> any())) :: non_neg_integer()
  def pull(plane_url, say \\ &IO.puts/1) do
    with {:ok, url} <- plane(plane_url),
         {:ok, origin} <- Client.connect_plane(url),
         {:ok, defaults} <- Client.client_defaults(origin),
         :ok <- configured(defaults, url),
         {:ok, saved} <- Link.call("config.set", params(defaults)) do
      report(saved, url, say)
      0
    else
      {:error, reason} ->
        say.("could not pull the defaults: " <> describe(reason))
        1

      {:nothing, message} ->
        say.(message)
        1
    end
  end

  @doc """
  The `config.set` params for a plane's defaults. Only what the plane says is sent: a
  role it leaves empty keeps this machine's choice, and no `api_key` keeps the saved key.
  """
  @spec params(map()) :: map()
  def params(defaults) do
    models =
      (defaults["models"] || %{})
      |> Enum.reject(fn {_role, model} -> model in [nil, ""] end)
      |> Map.new()

    %{
      "command_id" => Protocol.command_id(),
      "provider" => defaults["provider"],
      "base_url" => defaults["base_url"]
    }
    |> put_present("auth", defaults["auth"])
    |> put_present("models", if(models == %{}, do: nil, else: models))
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp plane(url) when is_binary(url) and url != "", do: {:ok, url}

  defp plane(_none) do
    case Credentials.fetch() do
      {:ok, %{plane_url: url}} -> {:ok, url}
      :error -> {:error, :logged_out}
    end
  end

  defp configured(%{"configured" => true}, _url), do: :ok

  defp configured(_defaults, url),
    do:
      {:nothing,
       "#{url} offers no defaults for local sessions; an administrator sets them under Settings → What people's own machines talk to"}

  defp report(saved, url, say) do
    say.("saved #{url}'s defaults to #{saved["path"]}")
    say.("  provider  #{saved["provider"]}#{base(saved["base_url"])}")

    for role <- ~w(default cheap expensive), is_binary(saved["models"][role]) do
      say.("  #{String.pad_trailing(role, 9)} #{saved["models"][role]}")
    end

    unless saved["api_key_set"] do
      say.("")

      say.(
        "no API key yet — the plane never hands one out. Add yours as api_key in #{saved["path"]},"
      )

      say.("set TROUPE_API_KEY, or paste it into the desktop app's Models settings.")
    end

    for %{"detail" => detail} <- saved["overrides"] || [] do
      say.("note: #{detail}")
    end
  end

  defp base(nil), do: ""
  defp base(url), do: " at #{url}"

  defp describe(:logged_out), do: "not signed in; run troupe login <plane-url>"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
