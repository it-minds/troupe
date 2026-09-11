defmodule Troupe.MCP.Server do
  @moduledoc """
  One configured MCP server.

  The credential is held here as a resolved value because the worker has to send it, but
  it arrives as a *reference* — the name of a secret the pod was given — and that is the
  only form anything else ever sees. `inspect/1` is overridden for the same reason: a
  crash report with a bearer token in it is a leaked credential.
  """

  @enforce_keys [:name, :url]
  defstruct [:name, :url, :credential, :credential_ref, header: "authorization", timeout_ms: 30_000]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          credential: String.t() | nil,
          credential_ref: String.t() | nil,
          header: String.t(),
          timeout_ms: pos_integer()
        }

  @doc """
  Build a server from configuration, resolving its secret reference.

  The reference names an environment variable, because that is how a pod receives a
  secret it was granted: the operator mounts it, the container sees it, and nothing in
  between — not the plane, not a config bundle, not the panel — ever holds the value.
  """
  @spec from_config(map() | keyword()) :: t()
  def from_config(config) do
    config = Map.new(config, fn {key, value} -> {to_string(key), value} end)
    reference = config["credential_ref"] || config["secret_ref"]

    %__MODULE__{
      name: config["name"],
      url: config["url"],
      credential_ref: reference,
      credential: resolve(reference, config["credential"]),
      header: config["header"] || "authorization",
      timeout_ms: config["timeout_ms"] || 30_000
    }
  end

  defp resolve(nil, explicit), do: explicit

  defp resolve(reference, explicit) do
    case System.get_env(reference) do
      nil -> explicit
      "" -> explicit
      value -> value
    end
  end

  @doc "The headers a call to this server carries. The service credential, and no more."
  @spec headers(t()) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{credential: nil}), do: []

  def headers(%__MODULE__{} = server) do
    [{server.header, value_for(server)}]
  end

  # A bearer token is conventionally prefixed; anything else — an API key header — is
  # sent as it is.
  defp value_for(%__MODULE__{header: "authorization", credential: credential}) do
    if String.contains?(credential, " "), do: credential, else: "Bearer " <> credential
  end

  defp value_for(%__MODULE__{credential: credential}), do: credential

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(server, opts) do
      concat([
        "#Troupe.MCP.Server<",
        to_doc(%{name: server.name, url: server.url, credential_ref: server.credential_ref}, opts),
        ">"
      ])
    end
  end
end
