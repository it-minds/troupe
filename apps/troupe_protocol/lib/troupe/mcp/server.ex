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
  crash report with a bearer token in it is a leaked credential. The headers a person's
  own server's entry names (Decision 820) often are one, and it leaves them out too.
  """

  @enforce_keys [:name, :url]
  defstruct [
    :name,
    :url,
    :credential,
    :credential_ref,
    # Whose credential goes out with a call. `:profile` is the service account in
    # `credential`, resolved once at discovery and the same for every session.
    # `:person` is the session's owner, and there is nothing resolved here at all: the
    # value is read per session, at call time, from the key manager. `:client_credentials`
    # is the profile's own identity, a token the pod gets by signing an assertion through
    # the key manager and puts in `credential` per call (Decision 747).
    credential_mode: :profile,
    header: "authorization",
    timeout_ms: 30_000,
    # What a bundle said about this server's tools: the permission they start at, and
    # which of them may be offered at all. Applied at discovery, so an unlisted tool is
    # not merely denied but absent from what a model can see.
    permission: :ask,
    tools: :all,
    # A person's own server that wants them signed in (Decision 741): where the daemon
    # keeps that sign-in, so `credential` is filled per call from it. Never set on a
    # pod, which holds nobody's sign-in.
    oauth: nil,
    # Where the MCP sessions this server issues are kept (`Troupe.MCP.Sessions`, Decision
    # 746): the table of whoever calls it, a local session or a pod. `nil` opens one per
    # call.
    sessions: nil,
    # The headers a person's own server's entry names (Decision 820), `{name, value}` with
    # each `{env:VAR}` already read, sent with every request beside the credential. A
    # bundle's server has none: it carries its one credential.
    headers: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          credential: String.t() | nil,
          credential_ref: String.t() | nil,
          header: String.t(),
          timeout_ms: pos_integer(),
          permission: :ask | :auto,
          tools: :all | [String.t()],
          oauth: map() | nil,
          sessions: :ets.tid() | nil,
          headers: [{String.t(), String.t()}]
        }

  # What the client sends on its own, per request: a header of the entry's with one of
  # these names would go out twice, or say something about the session it has no say in.
  @reserved ~w(accept content-type content-length host connection transfer-encoding
               mcp-session-id mcp-protocol-version)
  @token ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/

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
    mode = mode(config["credential_mode"])

    %__MODULE__{
      name: config["name"],
      url: config["url"],
      credential_ref: reference,
      credential_mode: mode,
      # Nothing is resolved for a person-mode server. There is no environment variable
      # to read and the value is not the pod's to hold: it belongs to whoever owns the
      # session, and is fetched per call. Nor for the profile's own identity, whose token
      # runs out and is asked for per call too.
      credential: if(mode == :profile, do: resolve(reference, config["credential"]), else: nil),
      header: config["header"] || "authorization",
      timeout_ms: config["timeout_ms"] || 30_000,
      permission: permission(config["permission"]),
      tools: allowlist(config["tools"]),
      headers: header_list(config["headers"])
    }
  end

  # In name order, so two reads of one entry are one credential to `Troupe.MCP.Sessions`;
  # a name the client sends itself is left out, which `header_problem/1` refused already.
  defp header_list(headers) when is_map(headers) do
    headers
    |> Enum.filter(fn {name, value} -> is_binary(name) and is_binary(value) end)
    |> Enum.reject(fn {name, _value} -> String.downcase(name) in @reserved end)
    |> Enum.sort()
  end

  defp header_list(_none), do: []

  @doc """
  Why an entry's headers cannot be sent, or `nil`: a name that is not an HTTP token, a
  value with a line break or another control character in it, or a name the client
  sends itself (`Accept`, `Mcp-Session-Id` and the like).
  """
  @spec header_problem(%{optional(String.t()) => String.t()}) :: String.t() | nil
  def header_problem(headers) when is_map(headers) do
    Enum.find_value(Enum.sort(headers), fn {name, value} ->
      cond do
        not Regex.match?(@token, name) ->
          "headers: #{inspect(name)} is not a header name"

        String.downcase(name) in @reserved ->
          "headers: #{name} is sent by Troupe itself, and cannot be set"

        not is_binary(value) or String.match?(value, ~r/[\x00-\x08\x0A-\x1F\x7F]/) ->
          "headers: the value of #{name} has a line break or a control character in it"

        true ->
          nil
      end
    end)
  end

  # Anything but an explicit `person` is `profile`: a typo in a bundle should leave a
  # server reaching out as the service account it always did, never start sending
  # somebody's own credential somewhere.
  defp mode(value) when value in ["person", :person], do: :person

  defp mode(value) when value in ["client_credentials", :client_credentials],
    do: :client_credentials

  defp mode(_value), do: :profile

  @doc """
  The slot a person-mode server's credential lives in, under its person.

  The bundle's `credential_ref` in person mode, which defaults to the server's name.
  """
  @spec slot(t()) :: String.t()
  def slot(%__MODULE__{credential_ref: ref, name: name}), do: ref || name

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

  @doc """
  The headers a call to this server carries: the ones its entry names (Decision 820), and
  the credential, which wins over one of the entry's with the same name — a sign-in's
  token over an `Authorization` written in the file, since the token is the one kept
  fresh.
  """
  @spec headers(t()) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{credential: nil, headers: headers}), do: headers

  def headers(%__MODULE__{} = server) do
    credential = String.downcase(server.header)

    Enum.reject(server.headers, fn {name, _value} -> String.downcase(name) == credential end) ++
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
