defmodule Troupe.Protocol.Endpoint do
  @moduledoc """
  Where the daemon listens, and how a client finds it.

  A Unix socket where the platform has one: its `0600` permissions are the whole
  authentication story, which is why nothing else is needed locally. Loopback TCP
  with a random token otherwise — same trust boundary, expressed with a file only the
  user can read rather than with a socket only the user can open.

  Whether `AF_UNIX` is available is detected at runtime rather than assumed from the
  OS, because OTP builds differ: a Windows build with `AF_UNIX` support gets the
  better path automatically.
  """

  @enforce_keys [:kind]
  defstruct [:kind, :path, :port, :token, :authenticator, :guard, :narrow]

  @type t :: %__MODULE__{
          kind: :unix | :tcp | :remote,
          path: Path.t() | nil,
          port: :inet.port_number() | nil,
          token: String.t() | nil,
          authenticator: (map() -> {:ok, map(), [atom()]} | {:error, term()}) | nil,
          guard: (map(), String.t(), map() -> :ok | {:error, term()}) | nil,
          narrow: (map() | nil, String.t(), map() -> map()) | nil
        }

  @doc "The endpoint this machine should use, honouring `TROUPE_DAEMON_SOCKET`."
  @spec default() :: t()
  def default do
    case System.get_env("TROUPE_DAEMON_SOCKET") do
      nil -> detect()
      "tcp" -> tcp()
      path -> %__MODULE__{kind: :unix, path: path}
    end
  end

  defp detect do
    if unix_sockets_available?(), do: unix(), else: tcp()
  end

  @doc "A Unix-socket endpoint at the standard path."
  @spec unix(Path.t() | nil) :: t()
  def unix(path \\ nil), do: %__MODULE__{kind: :unix, path: path || socket_path()}

  @doc "A loopback TCP endpoint with a fresh token. Port 0 means the OS picks one."
  @spec tcp(:inet.port_number()) :: t()
  def tcp(port \\ 0) do
    %__MODULE__{kind: :tcp, port: port, token: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)}
  end

  @doc """
  A worker pod's endpoint: a port, and a function that decides who is calling.

  Locally the socket's permissions are the authentication; in a cluster they are a
  signed token whose audience is this pod, which is a decision the worker makes and the
  protocol layer only carries. Injected rather than branched on, so the gateway stays a
  gateway and does not learn about JWKS.
  """
  @spec remote(:inet.port_number(), (map() -> {:ok, map(), [atom()]} | {:error, term()}), keyword()) :: t()
  def remote(port, authenticator, opts \\ []) do
    %__MODULE__{
      kind: :remote,
      port: port,
      authenticator: authenticator,
      # Consulted before every command, because a token is minted once and an ACL can
      # change while it is still valid: a collaborator whose access was revoked has a
      # perfectly good token and must still be refused.
      guard: Keyword.get(opts, :guard),
      # Applied to an answer before it goes back, for the answers that are about more
      # than the caller may see: a listing of every session on a pod.
      narrow: Keyword.get(opts, :narrow)
    }
  end

  @doc """
  Whether this OTP build can do `AF_UNIX`.

  Decided by trying, because the answer is a property of the build rather than of the
  operating system name.
  """
  @spec unix_sockets_available?() :: boolean()
  def unix_sockets_available? do
    # Asked once per VM: it is a property of the build, and the answer is wanted on a
    # poll loop while a daemon is starting.
    case :persistent_term.get({__MODULE__, :af_unix}, nil) do
      nil ->
        answer = probe_unix_socket()
        :persistent_term.put({__MODULE__, :af_unix}, answer)
        answer

      answer ->
        answer
    end
  end

  defp probe_unix_socket do
    path = Path.join(System.tmp_dir!(), "troupe-afunix-probe-#{:erlang.unique_integer([:positive])}")

    try do
      case :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}]) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _} ->
          false
      end
    rescue
      _ -> false
    after
      File.rm(path)
    end
  end

  @doc "The standard socket path: `$XDG_RUNTIME_DIR/troupe/daemon.sock`."
  @spec socket_path() :: Path.t()
  def socket_path do
    base =
      System.get_env("XDG_RUNTIME_DIR") ||
        Path.join(System.user_home!(), ".troupe/run")

    Path.join([base, "troupe", "daemon.sock"])
  end

  @doc "The discovery file a TCP daemon writes so clients can find its port and token."
  @spec discovery_path() :: Path.t()
  def discovery_path do
    base =
      System.get_env("LOCALAPPDATA") ||
        System.get_env("XDG_RUNTIME_DIR") ||
        Path.join(System.user_home!(), ".troupe/run")

    Path.join([base, "troupe", "daemon.json"])
  end

  @doc """
  Record where clients can find this daemon.

  Every local transport, not only TCP. It used to be TCP alone, because a Unix socket is
  found at a known path and needs no file to say so — but the daemon now also serves a
  WebSocket for clients that can use neither, and that entry has to live somewhere. One
  file describing the daemon is better than one file per transport, so a Unix socket
  writes its path here too and the WebSocket is a second key beside it.
  """
  @spec publish!(t()) :: :ok
  def publish!(%__MODULE__{kind: :unix, path: path}) do
    merge!(%{"transport" => "unix", "path" => path})
  end

  def publish!(%__MODULE__{kind: :remote}), do: :ok

  def publish!(%__MODULE__{kind: :tcp} = endpoint) do
    merge!(%{
      "transport" => "tcp",
      "port" => endpoint.port,
      "token" => endpoint.token
    })
  end

  # One file, written by two things that know different halves of it. Merging rather
  # than replacing means the primary transport and the WebSocket can be published in
  # either order, and a listener that restarts does not take the other one out with it.
  defp merge!(entry) do
    path = discovery_path()
    File.mkdir_p!(Path.dirname(path))

    existing =
      with {:ok, contents} <- File.read(path),
           {:ok, json} when is_map(json) <- Jason.decode(contents) do
        json
      else
        _ -> %{}
      end

    File.write!(path, Jason.encode!(Map.merge(existing, entry)))
    File.chmod!(path, 0o600)
    :ok
  end

  @doc """
  Record a loopback WebSocket *beside* whatever the primary transport published.

  A browser cannot open a Unix socket and cannot open a raw TCP one, so the daemon's
  own transport is unreachable from a page whichever of the two it is using. The
  WebSocket is a second door to the same daemon, and it is published as a second entry
  rather than as a second file so that a client reads one path and finds everything.

  Merged rather than written, so this and the primary transport can be published in
  either order and neither takes the other out of the file.
  """
  @spec publish_ws!(t()) :: :ok
  def publish_ws!(%__MODULE__{port: port, token: token}) when is_integer(port) do
    merge!(%{"ws" => %{"port" => port, "token" => token}})
  end

  @doc "Remove the WebSocket entry, leaving the primary transport's alone."
  @spec retract_ws() :: :ok
  def retract_ws do
    path = discovery_path()

    with {:ok, contents} <- File.read(path),
         {:ok, json} when is_map(json) <- Jason.decode(contents) do
      File.write!(path, Jason.encode!(Map.delete(json, "ws")))
    end

    :ok
  end

  @doc "Remove whatever `publish!/1` left behind."
  @spec retract(t()) :: :ok
  def retract(%__MODULE__{kind: :unix, path: path}) do
    File.rm(path)
    File.rm(discovery_path())
    :ok
  end

  def retract(%__MODULE__{kind: :tcp}) do
    File.rm(discovery_path())
    :ok
  end

  def retract(%__MODULE__{kind: :remote}), do: :ok

  @doc "Read the endpoint a running daemon published, if any."
  @spec discover() :: {:ok, t()} | {:error, :not_running}
  def discover do
    unix = default()

    cond do
      unix.kind == :unix and File.exists?(unix.path) -> {:ok, unix}
      File.exists?(discovery_path()) -> read_discovery()
      true -> {:error, :not_running}
    end
  end

  defp read_discovery do
    case File.read(discovery_path()) do
      {:ok, contents} -> contents |> Jason.decode() |> from_discovery()
      _ -> {:error, :not_running}
    end
  end

  defp from_discovery({:ok, %{"transport" => "unix", "path" => path}}),
    do: {:ok, %__MODULE__{kind: :unix, path: path}}

  defp from_discovery({:ok, %{"port" => port} = json}),
    do: {:ok, %__MODULE__{kind: :tcp, port: port, token: Map.get(json, "token")}}

  defp from_discovery(_other), do: {:error, :not_running}

  @doc """
  The WebSocket a graphical client should dial, if this daemon published one.

  Separate from `discover/0` because it answers a different question: `discover/0` finds
  the best transport *this* process can use, and a page has only one choice.
  """
  @spec discover_ws() :: {:ok, %{port: :inet.port_number(), token: String.t()}} | {:error, :not_running}
  def discover_ws do
    with {:ok, contents} <- File.read(discovery_path()),
         {:ok, %{"ws" => %{"port" => port, "token" => token}}} <- Jason.decode(contents) do
      {:ok, %{port: port, token: token}}
    else
      _ -> {:error, :not_running}
    end
  end

  @doc "A human-readable description, for errors and logs."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{kind: :unix, path: path}), do: "unix:#{path}"
  def describe(%__MODULE__{kind: :tcp, port: port}), do: "tcp:127.0.0.1:#{port}"
  def describe(%__MODULE__{kind: :remote, port: port}), do: "remote:0.0.0.0:#{port}"

  @doc "The `:gen_tcp.connect/3` arguments for reaching this endpoint."
  @spec connect_args(t()) :: {term(), :inet.port_number()}
  def connect_args(%__MODULE__{kind: :unix, path: path}), do: {{:local, path}, 0}
  def connect_args(%__MODULE__{kind: :tcp, port: port}), do: {{127, 0, 0, 1}, port}
  def connect_args(%__MODULE__{kind: :remote, port: port}), do: {{127, 0, 0, 1}, port}
end
