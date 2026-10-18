defmodule Troupe.Plane.Signing do
  @moduledoc """
  The plane's own signing key, and what it signs for people's machines (#657).

  An Ed25519 key in OpenBao's transit engine, `troupe-plane-signing` unless the deployment
  names another (`:plane_signing_key` in the plane's `:transit` configuration), created the
  first time anything asks for it and never exportable: the plane asks transit to sign and
  gets a signature back, and holds no copy of the key, so a plane that is taken over signs
  while it is taken over and forges nothing afterwards. It is not the release key, which
  signs releases in CI and is compiled into every client; this one is the plane's word on
  what its clients should do, and they pin it at sign-in.

  It signs two answers, `me.client_versions` and `me.client_defaults`, as
  `Troupe.Protocol.PlaneSignature` lays them out. An answer the plane cannot sign, because
  OpenBao does not answer, goes out unsigned and is logged: a client that pinned the key
  refuses it, and one from before this takes it as it always did.

  A rotation makes a new version of the key, which signs from then on; every client that
  pinned the old one refuses what the new one signs until its person accepts it, with the
  fingerprint shown, as an SSH host key is accepted.

  The plane's OpenBao policy for it is `Troupe.KMS.Policy.plane_signing/2`: create and
  read the key, rotate it, sign with it; nothing that exports it.
  """

  alias Troupe.Plane.Tokens
  alias Troupe.Protocol.PlaneSignature

  require Logger

  @default_name "troupe-plane-signing"

  @doc "The transit key's name."
  @spec name() :: String.t()
  def name,
    do: Application.get_env(:troupe_plane, :transit, [])[:plane_signing_key] || @default_name

  @doc """
  The key: its current version's public half, fingerprint and when it was made, and every
  version's, newest first. Created first where there is none.
  """
  @spec key(keyword()) :: {:ok, map()} | {:error, term()}
  def key(opts \\ []) do
    case read(opts) do
      {:error, :not_found} ->
        create(opts)
        read(opts)

      other ->
        other
    end
  end

  @doc "The key as `/.well-known/troupe-signing-key` serves it: no version list."
  @spec published(keyword()) :: {:ok, map()} | {:error, term()}
  def published(opts \\ []) do
    with {:ok, key} <- key(opts) do
      {:ok, Map.take(key, ["algorithm", "public_key", "fingerprint", "version", "created_at"])}
    end
  end

  @doc """
  An answer with its `signed` beside it, `kind` being what it is
  (`PlaneSignature.kinds/0`). Unsigned, and logged, where transit could not sign.
  """
  @spec signed(String.t(), map(), keyword()) :: map()
  def signed(kind, answer, opts \\ []) do
    case sign(kind, answer, opts) do
      {:ok, envelope} ->
        Map.put(answer, "signed", envelope)

      {:error, reason} ->
        Logger.warning(
          "troupe plane: #{kind} goes out unsigned, and a client that pinned this plane's key " <>
            "refuses it: #{inspect(reason)}"
        )

        answer
    end
  end

  @doc "Sign `body` as `kind`: the envelope an answer carries as `signed`."
  @spec sign(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sign(kind, body, opts \\ []) do
    document =
      PlaneSignature.document(kind, body, [plane: plane_url()] ++ Keyword.take(opts, [:now]))

    # The version transit signed with is the one it names, which another replica's
    # rotation may have made newer than the one read a moment before.
    with {:ok, key} <- key(opts),
         {:ok, version, signature} <- transit_sign(document, opts),
         {:ok, key} <- if(version == key["version"], do: {:ok, key}, else: read(opts)),
         %{"fingerprint" => fingerprint} <-
           Enum.find(key["versions"], &(&1["version"] == version)) do
      {:ok, PlaneSignature.envelope(document, signature, fingerprint)}
    else
      nil -> {:error, :unknown_version}
      error -> error
    end
  end

  @doc """
  A new version of the key, which signs from now on. The versions before stay in transit,
  unused: nothing is signed with them again, and nothing a client holds is checked against
  them but the pin it accepted.
  """
  @spec rotate(keyword()) :: {:ok, %{before: map(), now: map()}} | {:error, term()}
  def rotate(opts \\ []) do
    with {:ok, before} <- key(opts),
         {:ok, _} <-
           Tokens.request(:post, "/v1/#{Tokens.mount(opts)}/keys/#{name()}/rotate", %{}, opts),
         {:ok, now} <- read(opts) do
      {:ok, %{before: before, now: now}}
    end
  end

  # -- transit ------------------------------------------------------------------------

  defp read(opts) do
    case Tokens.request(:get, "/v1/#{Tokens.mount(opts)}/keys/#{name()}", nil, opts) do
      {:ok, %{"data" => %{"type" => "ed25519", "keys" => keys, "latest_version" => latest}}} ->
        describe(keys, latest)

      {:ok, %{"data" => %{"type" => type}}} ->
        {:error, {:not_ed25519, type}}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  # Not exportable, and no plaintext backup: nothing about the key leaves transit but its
  # public half. Two replicas creating it at once is one key, which the read after says.
  defp create(opts) do
    case Tokens.request(
           :post,
           "/v1/#{Tokens.mount(opts)}/keys/#{name()}",
           %{"type" => "ed25519", "exportable" => false, "allow_plaintext_backup" => false},
           opts
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.info("troupe plane: creating #{name()}: #{inspect(reason)}")
    end
  end

  defp describe(keys, latest) do
    versions =
      keys
      |> Enum.flat_map(fn {version, %{"public_key" => encoded} = entry} ->
        case Base.decode64(encoded) do
          {:ok, <<_::256>> = raw} ->
            [
              raw
              |> PlaneSignature.key_json()
              |> Map.merge(%{
                "version" => String.to_integer(version),
                "created_at" => entry["creation_time"]
              })
            ]

          _other ->
            []
        end
      end)
      |> Enum.sort_by(& &1["version"], :desc)

    case Enum.find(versions, &(&1["version"] == latest)) do
      nil -> {:error, :no_public_key}
      current -> {:ok, Map.put(current, "versions", versions)}
    end
  end

  defp transit_sign(document, opts) do
    body = %{"input" => Base.encode64(document)}

    case Tokens.request(:post, "/v1/#{Tokens.mount(opts)}/sign/#{name()}", body, opts) do
      {:ok, %{"data" => %{"signature" => "vault:v" <> rest}}} ->
        with [version, encoded] <- String.split(rest, ":", parts: 2),
             {version, ""} <- Integer.parse(version),
             {:ok, signature} <- Base.decode64(encoded) do
          {:ok, version, signature}
        else
          _unread -> {:error, :unexpected_signature}
        end

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  defp plane_url do
    case Application.get_env(:troupe_plane, :base_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _none -> nil
    end
  end
end
