defmodule Troupe.Keyring do
  @moduledoc """
  The operating system's credential store, for a secret that must outlive the process
  holding it and must never be a file: Windows' Credential Manager, the macOS keychain,
  the Secret Service on Linux (`secret-tool`).

  One user's store, so an entry is readable by its owner's processes alone. A machine
  with no store (a Linux box with no keyring agent, a Windows whose policy forbids the
  PowerShell this calls) answers `{:error, :unavailable}`, and the caller keeps the
  secret in memory only and says so: a file is exactly what a store is for not being.

  Entries are named `<service>/<name>`. The service is `troupe` unless
  `TROUPE_KEYRING_SERVICE` names another, which a test or a scratch install does so that
  nothing it writes lands beside, or over, the person's own entries. A value is kept as
  given; callers keep to printable ASCII (the daemon keeps base64 of JSON), since each
  platform's tool takes it through a shell or a console.

  `:troupe_protocol, :keyring` names the module that does the work: `Troupe.Keyring.OS`,
  or `Troupe.Keyring.Memory` in a test, which keeps entries in this VM.
  """

  @type name :: String.t()

  @callback get(String.t()) :: {:ok, String.t()} | :none | {:error, term()}
  @callback put(String.t(), String.t()) :: :ok | {:error, term()}
  @callback delete(String.t()) :: :ok | {:error, term()}

  @doc "The entry's value, `:none` where there is no entry, or why the store could not say."
  @spec get(name()) :: {:ok, String.t()} | :none | {:error, term()}
  def get(name), do: backend().get(entry(name))

  @doc "Writes the entry, replacing one of the same name."
  @spec put(name(), String.t()) :: :ok | {:error, term()}
  def put(name, value) when is_binary(value), do: backend().put(entry(name), value)

  @doc "Removes the entry. `:ok` where there was none."
  @spec delete(name()) :: :ok | {:error, term()}
  def delete(name), do: backend().delete(entry(name))

  @doc "The full name an entry is kept under: `<service>/<name>`."
  @spec entry(name()) :: String.t()
  def entry(name), do: service() <> "/" <> name

  @doc "The service entries are kept under: `troupe`, or `TROUPE_KEYRING_SERVICE`."
  @spec service() :: String.t()
  def service do
    case System.get_env("TROUPE_KEYRING_SERVICE") do
      value when is_binary(value) and value != "" -> value
      _ -> "troupe"
    end
  end

  defp backend, do: Application.get_env(:troupe_protocol, :keyring, Troupe.Keyring.OS)
end
