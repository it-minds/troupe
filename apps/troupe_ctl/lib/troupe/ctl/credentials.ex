defmodule Troupe.Ctl.Credentials do
  @moduledoc """
  Where a logged-in plane's refresh token lives.

  One file, `0600`, in a `0700` directory: the same trust boundary the local daemon's
  socket uses, written the same way. If you can read it you are the user who owns it.

  A refresh token and not a session token, because a session token is short and
  audience-bound and there is nothing to be gained by writing one down. What is stored
  is what lets `troupe` work tomorrow without asking again — and it is stored per plane,
  so a person who works against two of them does not have to log in twice on every
  switch.
  """

  @doc "Where credentials are kept."
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    Keyword.get_lazy(opts, :path, fn ->
      base =
        System.get_env("TROUPE_CONFIG_HOME") ||
          System.get_env("XDG_CONFIG_HOME") ||
          Path.join(System.user_home!(), ".config")

      Path.join([base, "troupe", "credentials.json"])
    end)
  end

  @doc "Everything stored, keyed by plane URL."
  @spec all(keyword()) :: map()
  def all(opts \\ []) do
    case opts |> path() |> File.read() do
      {:ok, contents} -> Jason.decode(contents) |> elem(1) |> normalise()
      {:error, _reason} -> %{}
    end
  end

  defp normalise(%{} = decoded), do: decoded
  defp normalise(_other), do: %{}

  @doc "What is stored for one plane, or `nil`."
  @spec get(String.t(), keyword()) :: map() | nil
  def get(plane_url, opts \\ []), do: opts |> all() |> Map.get(String.trim_trailing(plane_url, "/"))

  @doc "The plane a bare `troupe --remote` should use: the only one, or the newest."
  @spec default(keyword()) :: map() | nil
  def default(opts \\ []) do
    opts
    |> all()
    |> Map.values()
    |> Enum.sort_by(& &1["stored_at"], :desc)
    |> List.first()
  end

  @doc """
  The record a command should use, given its options.

  `--plane` when one was named, the default otherwise, and whatever a test injected
  before either. One function because there were two, and they disagreed: `troupe admin
  --plane <url> overview` read the flag, dropped it, and answered from whichever plane
  happened to be the most recently logged into.
  """
  @spec for(keyword()) :: map() | nil
  def for(opts) do
    case Keyword.get(opts, :credentials) do
      nil -> named_or_default(opts)
      record -> record
    end
  end

  defp named_or_default(opts) do
    case Keyword.get(opts, :plane) do
      nil -> default(opts)
      plane -> get(plane, opts)
    end
  end

  @doc """
  Store one plane's credentials.

  The file is written whole and then chmod'd, rather than created with a mode: an
  `File.write!` that raced a reader would be a window in which the token was readable,
  and the window is the thing to avoid.
  """
  @spec put(String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def put(plane_url, record, opts \\ []) do
    file = path(opts)
    directory = Path.dirname(file)

    with :ok <- File.mkdir_p(directory),
         :ok <- tighten(directory),
         contents = Jason.encode!(Map.put(all(opts), String.trim_trailing(plane_url, "/"), record), pretty: true),
         :ok <- write_private(file, contents) do
      :ok
    else
      {:error, reason} -> {:error, "could not write #{file}: #{:file.format_error(reason)}"}
    end
  end

  # Best effort, and deliberately so. The directory Troupe made is Troupe's to tighten;
  # one it was pointed at may be somebody else's, and refusing to store credentials
  # because a parent directory has a different owner would be a failure for no gain —
  # the file itself is `0600` either way, which is the part that matters.
  defp tighten(directory) do
    File.chmod(directory, 0o700)
    :ok
  end

  # Created with the right mode from the start, by writing to a fresh file the process
  # owns and renaming it into place. A rename is atomic, so a reader sees either the old
  # credentials or the new ones and never a half-written file.
  defp write_private(file, contents) do
    scratch = file <> ".#{System.unique_integer([:positive])}"

    with :ok <- File.write(scratch, contents),
         :ok <- File.chmod(scratch, 0o600),
         :ok <- File.rename(scratch, file) do
      :ok
    else
      error ->
        File.rm(scratch)
        error
    end
  end

  @doc "Forget one plane."
  @spec forget(String.t(), keyword()) :: :ok
  def forget(plane_url, opts \\ []) do
    remaining = Map.delete(all(opts), String.trim_trailing(plane_url, "/"))

    if remaining == %{} do
      File.rm(path(opts))
      :ok
    else
      write_private(path(opts), Jason.encode!(remaining, pretty: true))
    end
  end

  @doc "Whether the file is readable by anyone but its owner, which it must not be."
  @spec private?(keyword()) :: boolean()
  def private?(opts \\ []) do
    case opts |> path() |> File.stat() do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      {:error, _reason} -> true
    end
  end
end
