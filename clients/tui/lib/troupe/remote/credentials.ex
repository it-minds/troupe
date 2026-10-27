defmodule Troupe.Remote.Credentials do
  @moduledoc """
  The refresh token on disk: `<config dir>/credentials.json`, readable by its
  owner and nobody else.

  `Troupe.OwnerOnly` does that, as it does for the daemon's own files: `0600` on unix,
  and on Windows an access list naming only the current user. Where `icacls` cannot
  run, the write still happens and `restricted?/1` says no, so a caller can warn
  rather than pretend.

  One entry per plane, keyed by its URL, so a laptop can be logged in to a
  work plane and a personal one at once. `current` is the plane `troupe
  --remote` opens without an argument.

  Beside the token, `sub`: who the plane said the person is at the last exchange. A
  label, not a credential, and what `troupe logout` tells the daemon, so that it lets go
  of the person's plane token and not of somebody else's (issue #381).

  The file is the machine's sign-in, not this program's: the desktop app reads and
  rotates the same token (root Decision 958), so one `troupe login` serves both and the
  daemon either hands it to. A provider rotates the refresh token on every use and
  refuses the old one from then on, so whoever refreshes holds `credentials.lock` beside
  the file meanwhile (`with_lock/1`), reads the token afresh inside it, and writes the
  rotated one before letting go; the other program waits its turn and spends the new
  token rather than the retired one. A lock a dead process left goes stale after a minute.
  """

  alias Troupe.Paths

  @type entry :: %{
          required(:plane_url) => String.t(),
          required(:refresh_token) => String.t() | nil,
          optional(:issuer) => String.t(),
          optional(:client_id) => String.t(),
          optional(:sub) => String.t(),
          optional(:name) => String.t(),
          optional(:saved_at) => integer()
        }

  # How long another program's refresh is waited for, and how old a lock is before it is
  # taken for one a dead process left.
  @lock_wait_ms 15_000
  @lock_stale_ms 60_000

  @doc """
  The credential file's path, beside `config.yaml`; on Windows one an older build kept
  under `~\\.config\\troupe` is moved here (`Troupe.Paths.config_file/2`).
  """
  @spec path() :: String.t()
  def path, do: Paths.config_file("credentials.json")

  @doc "The lock file's path: taken by whichever program is refreshing the token."
  @spec lock_path() :: String.t()
  def lock_path, do: Path.join(Paths.config_dir(), "credentials.lock")

  @doc """
  Run `fun` while nothing else on this machine refreshes the token: the desktop app
  holds the same lock around its own refresh. Waits up to fifteen seconds for the other
  holder, breaks a lock older than a minute, and past the wait goes ahead anyway, since
  a sign-in that cannot be renewed is the worse outcome. Always let go of afterwards.
  """
  @spec with_lock((-> result)) :: result when result: term()
  def with_lock(fun) do
    lock = lock_path()
    File.mkdir_p!(Path.dirname(lock))
    acquire(lock, System.monotonic_time(:millisecond) + @lock_wait_ms)

    try do
      fun.()
    after
      _ = File.rm(lock)
    end
  end

  defp acquire(lock, deadline) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, device} ->
        File.close(device)

      {:error, :eexist} ->
        if stale?(lock) or System.monotonic_time(:millisecond) > deadline do
          _ = File.rm(lock)
        else
          Process.sleep(50)
        end

        acquire(lock, deadline)

      # A directory that cannot hold the lock cannot hold the file either; the refresh
      # goes ahead and says so where it writes.
      {:error, _reason} ->
        :ok
    end
  end

  defp stale?(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        System.os_time(:second) - mtime > div(@lock_stale_ms, 1_000)

      {:error, _} ->
        false
    end
  end

  @doc "Every plane this machine is logged in to, newest first."
  @spec list() :: [entry()]
  def list do
    read()
    |> Map.get("planes", %{})
    |> Enum.map(fn {url, entry} -> entry(url, entry) end)
    |> Enum.sort_by(& &1.saved_at, :desc)
  end

  @doc "One plane's credentials; without a URL, the current one."
  @spec fetch(String.t() | nil) :: {:ok, entry()} | :error
  def fetch(plane_url \\ nil) do
    data = read()
    url = plane_url || data["current"]

    case url && get_in(data, ["planes", url]) do
      nil -> :error
      entry -> {:ok, entry(url, entry)}
    end
  end

  @doc "Writes one plane's credentials and makes it the current plane."
  @spec put(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def put(plane_url, fields) when is_map(fields) do
    entry =
      fields
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("saved_at", System.system_time(:millisecond))

    data =
      read()
      |> Map.put("current", plane_url)
      |> Map.update("planes", %{plane_url => entry}, &Map.put(&1, plane_url, entry))

    write(data)
  end

  @doc "Forgets one plane, or every plane when given `:all`."
  @spec delete(String.t() | :all) :: {:ok, String.t()} | {:error, term()}
  def delete(:all) do
    case File.rm(path()) do
      :ok -> {:ok, path()}
      {:error, :enoent} -> {:ok, path()}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(plane_url) do
    data = read()
    planes = data |> Map.get("planes", %{}) |> Map.delete(plane_url)

    current =
      case data["current"] do
        ^plane_url -> planes |> Map.keys() |> List.first()
        other -> other
      end

    write(%{"planes" => planes, "current" => current})
  end

  @doc """
  Whether the file on disk is readable only by its owner. A missing file is
  `true`: there is nothing to leak.
  """
  @spec restricted?(String.t()) :: boolean()
  def restricted?(file \\ path()), do: Troupe.OwnerOnly.restricted?(file)

  defp entry(url, %{} = entry) do
    %{
      plane_url: url,
      refresh_token: entry["refresh_token"],
      issuer: entry["issuer"],
      client_id: entry["client_id"],
      sub: entry["sub"],
      name: entry["name"],
      saved_at: entry["saved_at"] || 0
    }
  end

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{} = data} <- Jason.decode(body) do
      data
    else
      _ -> %{"planes" => %{}, "current" => nil}
    end
  end

  defp write(data) do
    file = path()
    File.mkdir_p!(Path.dirname(file))

    with :ok <- File.write(file, Jason.encode_to_iodata!(data)),
         :ok <- Troupe.OwnerOnly.restrict(file) do
      {:ok, file}
    end
  end
end
