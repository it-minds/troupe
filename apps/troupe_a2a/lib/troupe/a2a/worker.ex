defmodule Troupe.A2A.Worker do
  @moduledoc """
  A worker pod, reached the way every client reaches one.

  The plane hands out a grant — an endpoint and a token minted for that pod — and the
  facade dials the pod directly over `Troupe.Protocol.Client`. The plane is not in the
  data path of a task any more than it is in the data path of a TUI session.

  Sockets here are short-lived and owned by the request process that opened them: the
  client monitors its owner, so a request that ends takes its socket with it, and a
  stream that outlives its token refreshes it on the open connection.
  """

  alias Troupe.A2A.Plane
  alias Troupe.Protocol.Client
  alias Troupe.Protocol.Error

  @connect_timeout 15_000

  @doc "Dial the pod a grant names, as the principal the grant was minted for."
  @spec connect(map()) :: {:ok, pid()} | {:error, Error.t()}
  def connect(%{"endpoint" => endpoint, "token" => token}) when is_binary(endpoint) do
    Client.connect(
      url: endpoint,
      token: token,
      client_info: %{"name" => "troupe-a2a", "version" => Troupe.A2A.version()},
      capabilities: %{"blobs" => true},
      timeout: @connect_timeout
    )
    |> case do
      {:ok, client} -> {:ok, client}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  def connect(_grant), do: {:error, Error.new(:unavailable, %{reason: "the grant names no pod"})}

  @doc """
  Open a session in `mode`, dial its pod, run `fun` with the client and the grant, and
  close the socket whatever `fun` did.
  """
  @type session_fun :: (pid(), map() -> term())

  @spec with_session(Plane.caller(), String.t(), String.t(), session_fun()) ::
          term() | {:error, Error.t()}
  def with_session(caller, session_id, mode, fun) do
    with {:ok, grant} <- Plane.open_session(caller, session_id, mode),
         {:ok, client} <- connect(grant) do
      try do
        fun.(client, grant)
      after
        Client.close(client)
      end
    end
  end

  @doc """
  Renew the connection's token before it runs out.

  `auth.expiring` arrives two minutes before `exp`. A fresh token from `token.mint`,
  presented with `auth.refresh`, renews on the socket that is already open, so a
  stream in the middle of a turn never notices.
  """
  @spec refresh(pid(), Plane.caller(), String.t()) :: :ok | {:error, Error.t()}
  def refresh(client, caller, session_id) do
    with {:ok, %{"token" => token}} <- Plane.mint(caller, session_id),
         params = %{"auth" => %{"token" => token}},
         {:ok, _result} <- Client.call(client, "auth.refresh", params) do
      :ok
    else
      {:ok, _other} -> {:error, Error.new(:unavailable, %{reason: "token.mint gave no token"})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Subscribe to a session's detail feed; `nil` starts live."
  @spec subscribe(pid(), String.t(), non_neg_integer() | nil) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def subscribe(client, session_id, from_seq) do
    opts = [level: :detail] ++ if(from_seq, do: [from_seq: from_seq], else: [])

    with {:ok, result} <- Client.subscribe(client, "session:" <> session_id, opts) do
      {:ok, result["head_seq"] || 0}
    end
  end

  @doc "Steer: text into the session."
  @spec send_input(pid(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def send_input(client, session_id, text) do
    Client.call(client, "input.send", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "text" => text
    })
  end

  @doc "Answer an approval."
  @spec respond(pid(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def respond(client, session_id, call_id, decision) do
    Client.call(client, "approval.respond", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "call_id" => call_id,
      "decision" => decision
    })
  end

  @doc "Stop the current turn."
  @spec cancel(pid(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def cancel(client, session_id) do
    Client.call(client, "turn.cancel", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id
    })
  end

  @doc "A file on the session's mounts, as `fs.read` returns it."
  @spec read_file(pid(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def read_file(client, session_id, path) do
    Client.call(client, "fs.read", %{"session_id" => session_id, "path" => path}, 60_000)
  end

  @doc "A blob's bytes, decoded."
  @spec read_blob(pid(), String.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_blob(client, session_id, digest) do
    params = %{"session_id" => session_id, "blob" => digest}

    with {:ok, %{"data" => data}} <- Client.call(client, "blob.get", params, 60_000),
         {:ok, bytes} <- Base.decode64(data) do
      {:ok, bytes}
    else
      :error -> {:error, Error.new(:internal_error, %{reason: "blob.get returned bad base64"})}
      {:ok, _other} -> {:error, Error.new(:internal_error, %{reason: "blob.get gave no data"})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end
end
