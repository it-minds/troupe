defmodule Troupe.Remote.TLS do
  @moduledoc """
  Transport security for every connection the remote client makes: HTTPS for
  discovery and the device flow, `wss` for the plane and worker sockets.

  Verification is against the operating system's trust store
  (`:public_key.cacerts_get/0`), which is what a laptop already trusts.
  `TROUPE_CA_FILE` adds certificates on top of it rather than replacing it, so
  an internal deployment behind a private CA works without turning verification
  off anywhere (Decision 74).
  """

  require Logger

  @doc """
  `:ssl` options for a connection to `host`. Plain `http`/`ws` gets `[]` — the
  caller decides whether a cleartext URL is acceptable.
  """
  @spec opts(String.t()) :: keyword()
  def opts(host) do
    [
      verify: :verify_peer,
      cacerts: cacerts(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      server_name_indication: to_charlist(host)
    ]
  end

  @doc "The DER certificates trusted for this run: the OS store plus `TROUPE_CA_FILE`."
  @spec cacerts() :: [binary()]
  def cacerts do
    case :persistent_term.get({__MODULE__, :cacerts}, nil) do
      nil ->
        certs = os_cacerts() ++ extra_cacerts(System.get_env("TROUPE_CA_FILE"))
        :persistent_term.put({__MODULE__, :cacerts}, certs)
        certs

      certs ->
        certs
    end
  end

  @doc "Forgets the cached trust store, so a changed `TROUPE_CA_FILE` is read again."
  @spec forget() :: :ok
  def forget, do: :persistent_term.erase({__MODULE__, :cacerts}) && :ok

  defp os_cacerts do
    :public_key.cacerts_get()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp extra_cacerts(nil), do: []

  defp extra_cacerts(path) do
    case File.read(path) do
      {:ok, pem} ->
        for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der

      {:error, reason} ->
        Logger.warning("TROUPE_CA_FILE #{path}: #{:file.format_error(reason)}")
        []
    end
  end
end
