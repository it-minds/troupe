defmodule Troupe.Plane.Connections do
  @moduledoc """
  What a person has connected, and how they connect one more.

  A person-mode MCP server reaches out as the session's owner, with a credential that
  person put in the key manager themselves. This module is everything the plane is
  allowed to know about that, which is deliberately very little:

  * **whether** a slot has been filled — `list` on the key manager's metadata, which
    answers versions and timestamps and no value at all;
  * **an assertion** for the caller's own subject, which the client exchanges itself.

  ## The plane never holds the value, and never holds a token that could read it

  `grant/2` does not take a value and does not return one. It returns an assertion the
  plane has just signed for the caller — the same kind a pod exchanges — and the client
  presents that to the key manager to get a token scoped to its own subtree.

  That is stronger than answering with a token the plane minted on the caller's behalf,
  which is what `stage-6.md` §3c sketched: a token the plane minted is a token the plane
  held, and a plane that held one could have read the slot. Here the only thing that
  crosses is a signed statement of *who the caller is*, which the plane is entitled to
  make because it is the thing that authenticated them.

  ## Removal is the person's

  The same grant writes and deletes: an admin can retire a server from the bundle and can
  neither read nor remove somebody's credential. There is no method here that deletes a
  slot, because there is no credential here that could.
  """

  alias Troupe.KMS
  alias Troupe.Plane.Tokens
  alias Troupe.Protocol.Error

  @doc """
  Whether this person has put something in this slot.

  `false` where the key manager cannot be reached, because "we could not ask" and "there
  is nothing there" lead to the same next step for the person — connect it — and an error
  in a listing of six servers would hide the five that answered.
  """
  @spec connected?(String.t(), String.t()) :: boolean()
  def connected?(subject, slot) do
    case metadata(subject, slot) do
      {:ok, :present} -> true
      _other -> false
    end
  end

  @doc """
  What a client needs in order to write its own credential into a slot.

  The assertion, and where to spend it. No value in, no value out.
  """
  @spec grant(String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def grant(subject, slot) do
    case Tokens.mint_kms_assertion(subject) do
      {:ok, assertion, claims} ->
        {:ok,
         %{
           "assertion" => assertion,
           "expires_at" => claims["exp"],
           "audience" => Tokens.kms_audience(),
           "key_manager" => %{
             "address" => address(),
             "mount" => mount(),
             "auth_path" => auth_path(),
             "role" => role(),
             # The path to write, spelled out, so a client is never in the business of
             # building one. A client that guessed would one day guess a path under
             # somebody else — and be refused, which is right, and confusing.
             "path" => KMS.slot_path(subject, slot)
           }
         }}

      {:error, reason} ->
        {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  @doc """
  Refuse a slot no bundle on the caller's profiles asks for.

  Not a security boundary — the key manager's policy is, and it would refuse a path under
  anybody else regardless. This is so that a typo puts nothing in a slot that will never
  be read, which is a credential sitting somewhere for no reason.
  """
  @spec known_slot([String.t()], String.t()) :: :ok | {:error, Error.t()}
  def known_slot(slots, slot) do
    if slot in slots do
      :ok
    else
      {:error,
       Error.new(:not_found, %{
         slot: slot,
         reason: "no server on your profiles asks for that slot",
         slots: Enum.sort(slots)
       })}
    end
  end

  # -- the key manager --------------------------------------------------------

  # KV v2 metadata: versions and timestamps, never a value. The plane's policy has `list`
  # and `read` here and nothing at all on the data path, which is the same absence that
  # stops it reading a session key.
  defp metadata(subject, slot) do
    path = subject |> KMS.slot_path(slot) |> encode()

    case Req.request(
           method: :get,
           url: address() <> "/v1/#{mount()}/metadata/#{path}",
           headers: [{"x-vault-token", token()}],
           decode_body: true,
           retry: false,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200}} -> {:ok, :present}
      {:ok, %{status: 404}} -> {:ok, :absent}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  defp config, do: Application.get_env(:troupe_plane, :transit, [])
  defp address, do: config()[:address]
  defp token, do: config()[:token] || ""
  defp mount, do: Application.get_env(:troupe_plane, :kms_mount, "secret")

  defp auth_path do
    Application.get_env(:troupe_plane, :person_auth_path, "jwt")
  end

  defp role do
    Application.get_env(:troupe_plane, :person_role, KMS.Policy.person_policy_name())
  end
end
