defmodule Troupe.Plane.ControlTLSFixture do
  @moduledoc """
  A control port's certificate, written the way cert-manager writes its Secret, into a
  directory of the test's own: `tls.crt`, `tls.key` and `ca.crt`. And a CA that signed
  nothing here, for a machine pinning the wrong one.

  The certificate names the control Service as the chart's does, and nothing else, so a
  client checks it by that name (`server_name`) whatever address it dials.
  """

  @name "troupe-plane-control.troupe-system.svc"

  @doc "The name the certificate carries."
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  Write a certificate into `base`/`control-tls` and a stranger's CA beside it. Answers the
  directory, the path of the CA that signed the certificate, and the path of the other.
  """
  @spec write!(Path.t()) :: %{dir: Path.t(), ca: Path.t(), other_ca: Path.t()}
  def write!(base) do
    %{server_config: server, client_config: client} = chain(@name)
    %{client_config: stranger} = chain("somewhere-else.example.test")

    dir = Path.join(base, "control-tls")
    File.mkdir_p!(dir)

    {key_type, key} = server[:key]
    File.write!(Path.join(dir, "tls.crt"), pem([{:Certificate, server[:cert], :not_encrypted}]))
    File.write!(Path.join(dir, "tls.key"), pem([{key_type, key, :not_encrypted}]))
    File.write!(Path.join(dir, "ca.crt"), certificates(client[:cacerts]))

    other_ca = Path.join(base, "other-ca.crt")
    File.write!(other_ca, certificates(stranger[:cacerts]))

    %{dir: dir, ca: Path.join(dir, "ca.crt"), other_ca: other_ca}
  end

  defp chain(name) do
    :public_key.pkix_test_data(%{
      server_chain: %{
        root: [digest: :sha256, key: {:namedCurve, :secp256r1}],
        intermediates: [],
        peer: [
          digest: :sha256,
          key: {:namedCurve, :secp256r1},
          extensions: [
            {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(name)}]}
          ]
        ]
      },
      client_chain: %{
        root: [digest: :sha256, key: {:namedCurve, :secp256r1}],
        intermediates: [],
        peer: [digest: :sha256, key: {:namedCurve, :secp256r1}]
      }
    })
  end

  defp certificates(ders), do: pem(for der <- ders, do: {:Certificate, der, :not_encrypted})

  defp pem(entries), do: :public_key.pem_encode(entries)
end
