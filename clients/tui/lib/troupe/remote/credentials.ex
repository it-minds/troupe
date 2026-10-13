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

  @doc "The credential file's path."
  @spec path() :: String.t()
  def path, do: Path.join(Paths.config_dir(), "credentials.json")

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
