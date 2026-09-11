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
  defstruct [:kind, :path, :port, :token]

  @type t :: %__MODULE__{
          kind: :unix | :tcp,
          path: Path.t() | nil,
          port: :inet.port_number() | nil,
          token: String.t() | nil
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

  @doc "Record a TCP endpoint where clients can find it. A no-op for Unix sockets."
  @spec publish!(t()) :: :ok
  def publish!(%__MODULE__{kind: :unix}), do: :ok

  def publish!(%__MODULE__{kind: :tcp} = endpoint) do
    path = discovery_path()
    File.mkdir_p!(Path.dirname(path))

    contents =
      Jason.encode!(%{
        "transport" => "tcp",
        "port" => endpoint.port,
        "token" => endpoint.token
      })

    File.write!(path, contents)
    File.chmod!(path, 0o600)
    :ok
  end

  @doc "Remove whatever `publish!/1` left behind."
  @spec retract(t()) :: :ok
  def retract(%__MODULE__{kind: :unix, path: path}) do
    File.rm(path)
    :ok
  end

  def retract(%__MODULE__{kind: :tcp}) do
    File.rm(discovery_path())
    :ok
  end

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
    with {:ok, contents} <- File.read(discovery_path()),
         {:ok, %{"port" => port} = json} <- Jason.decode(contents) do
      {:ok, %__MODULE__{kind: :tcp, port: port, token: Map.get(json, "token")}}
    else
      _ -> {:error, :not_running}
    end
  end

  @doc "A human-readable description, for errors and logs."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{kind: :unix, path: path}), do: "unix:#{path}"
  def describe(%__MODULE__{kind: :tcp, port: port}), do: "tcp:127.0.0.1:#{port}"

  @doc "The `:gen_tcp.connect/3` arguments for reaching this endpoint."
  @spec connect_args(t()) :: {term(), :inet.port_number()}
  def connect_args(%__MODULE__{kind: :unix, path: path}), do: {{:local, path}, 0}
  def connect_args(%__MODULE__{kind: :tcp, port: port}), do: {{127, 0, 0, 1}, port}
end
