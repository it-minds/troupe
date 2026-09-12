defmodule Troupe.MCP.Server do
  @moduledoc """
  One configured MCP server.

  In `troupe_protocol` rather than in core because two very different callers hold this
  same contract: a worker pod, which offers a *profile's* MCP servers to every session on
  it, and a harness, which offers a *person's* to one session they are attached to. Both
  speak the same wire protocol to the same kind of server, and a second copy of it in the
  TUI would be a second thing to keep in step.

  The credential is held here as a resolved value because the worker has to send it, but
  it arrives as a *reference* — the name of a secret the pod was given — and that is the
  only form anything else ever sees. `inspect/1` is overridden for the same reason: a
  crash report with a bearer token in it is a leaked credential.
  """

  @enforce_keys [:name, :url]
  defstruct [
    :name,
    :url,
    :credential,
    :credential_ref,
    header: "authorization",
    timeout_ms: 30_000,
    # What a bundle said about this server's tools: the permission they start at, and
    # which of them may be offered at all. Applied at discovery, so an unlisted tool is
    # not merely denied but absent from what a model can see.
    permission: :ask,
    tools: :all
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          credential: String.t() | nil,
          credential_ref: String.t() | nil,
          header: String.t(),
          timeout_ms: pos_integer(),
          permission: :ask | :auto,
          tools: :all | [String.t()]
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
      timeout_ms: config["timeout_ms"] || 30_000,
      permission: permission(config["permission"]),
      tools: allowlist(config["tools"])
    }
  end

  # Anything but an explicit `auto` is `ask`. A typo in a bundle should make a tool ask
  # more, never less.
  defp permission(value) when value in ["auto", :auto], do: :auto
  defp permission(_value), do: :ask

  defp allowlist(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp allowlist(_all), do: :all

  @doc "Whether a tool the server listed may be offered under this configuration."
  @spec offers?(t(), String.t()) :: boolean()
  def offers?(%__MODULE__{tools: :all}, _remote_name), do: true
  def offers?(%__MODULE__{tools: list}, remote_name), do: remote_name in list

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
        to_doc(
          %{name: server.name, url: server.url, credential_ref: server.credential_ref},
          opts
        ),
        ">"
      ])
    end
  end
end
