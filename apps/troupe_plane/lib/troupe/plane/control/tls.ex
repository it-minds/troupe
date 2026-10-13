defmodule Troupe.Plane.Control.TLS do
  @moduledoc """
  The control port's certificate, and the CA a registered machine pins.

  The chart has cert-manager issue a certificate for the control Service and mounts its
  Secret in the directory `:control_tls` names (`TROUPE_PLANE_CONTROL_TLS_DIR`), as
  cert-manager writes it: `tls.crt`, the certificate and the chain above it, `tls.key`,
  and `ca.crt`, the CA that signed it. A machine is given `ca.crt` when it is registered
  and trusts nothing else for this channel, so the CA is what it pins, and the chart's own
  CA lasts ten years while the certificate under it is renewed.

  Each file is read when it is wanted, at a handshake and at a registration, rather than
  once at boot: cert-manager renews the certificate in place and the kubelet swaps the
  files under a running pod, and a plane that kept the first one would serve it until
  it expired.
  """

  @doc "Where the certificate's files are, or `nil` on a plane given none."
  @spec dir() :: Path.t() | nil
  def dir, do: Application.get_env(:troupe_plane, :control_tls)

  @doc """
  What `:ssl.handshake/3` takes to serve the certificate in `dir`: TLS 1.3 or 1.2, the
  certificate with its chain, and its key. An error is a sentence saying what is missing.
  """
  @spec server_options(Path.t() | nil) :: {:ok, keyword()} | {:error, String.t()}
  def server_options(dir \\ dir())

  def server_options(nil), do: {:error, no_certificate()}

  def server_options(dir) do
    with {:ok, certs} <- certificates(Path.join(dir, "tls.crt")),
         {:ok, key} <- key(Path.join(dir, "tls.key")) do
      {:ok, [versions: [:"tlsv1.3", :"tlsv1.2"], certs_keys: [%{cert: certs, key: key}]]}
    end
  end

  @doc """
  The CA a machine pins, as the PEM text in `ca.crt`: what `admin.host.register` and
  `admin.host.rotate` answer beside the secret. Not secret: it proves nothing on its own.
  """
  @spec ca(Path.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def ca(dir \\ dir())

  def ca(nil), do: {:error, no_certificate()}

  def ca(dir) do
    path = Path.join(dir, "ca.crt")

    with {:ok, _certs} <- certificates(path) do
      {:ok, File.read!(path)}
    end
  end

  defp no_certificate,
    do:
      "this plane's control port has no certificate (the chart's plane.controlTls), and a " <>
        "registered machine enrols over TLS only"

  defp certificates(path) do
    with {:ok, entries} <- read(path),
         [_ | _] = certs <- for({:Certificate, der, :not_encrypted} <- entries, do: der) do
      {:ok, certs}
    else
      [] -> {:error, "#{path} holds no certificate"}
      {:error, _why} = error -> error
    end
  end

  @key_types [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]

  defp key(path) do
    with {:ok, entries} <- read(path),
         [key | _] <-
           for({type, der, :not_encrypted} <- entries, type in @key_types, do: {type, der}) do
      {:ok, key}
    else
      [] -> {:error, "#{path} holds no private key Troupe can use"}
      {:error, _why} = error -> error
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, pem} -> {:ok, :public_key.pem_decode(pem)}
      {:error, :enoent} -> {:error, "#{path} is not there yet"}
      {:error, reason} -> {:error, "#{path} cannot be read (#{:file.format_error(reason)})"}
    end
  end
end
