defmodule Troupe.Keyring.OS do
  @moduledoc """
  The platform's own store, through the tool each platform has for it, found on `PATH`
  alone (`Troupe.Executable`) and started hidden. A secret never goes on a command line,
  which other users can read: it reaches the tool through an environment variable, the
  child's own, and from there a pipe.

  - **Windows**: Credential Manager, a generic credential persisted on this machine,
    through `CredWriteW`, `CredReadW` and `CredDeleteW`, called from Windows PowerShell.
  - **macOS**: the login keychain, through `security -i`, given its command on a pipe.
  - **Linux and the other unixes**: the Secret Service, through `secret-tool`, given the
    secret on its standard input. No `secret-tool`, or no agent answering it, is
    `{:error, :unavailable}`.
  """

  @behaviour Troupe.Keyring

  @timeout_ms 30_000

  @impl true
  def get(entry), do: run(:get, entry, nil)

  @impl true
  def put(entry, value), do: run(:put, entry, value)

  @impl true
  def delete(entry), do: run(:delete, entry, nil)

  defp run(op, entry, value) do
    case :os.type() do
      {:win32, _} -> windows(op, entry, value)
      {:unix, :darwin} -> mac(op, entry, value)
      {:unix, _} -> secret_tool(op, entry, value)
    end
  end

  # -- Windows ------------------------------------------------------------------

  # ASCII only: Windows PowerShell 5.1 reads its command as the console's code page.
  @windows_script ~S"""
  $ErrorActionPreference = 'Stop'
  try {
    Add-Type -TypeDefinition @'
  using System;
  using System.Runtime.InteropServices;
  using System.Text;
  public static class TroupeKeyring {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
      public int Flags; public int Type; public string TargetName; public string Comment;
      public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
      public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
      public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWriteW(ref CREDENTIAL credential, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredReadW(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDeleteW(string target, int type, int flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr credential);
    const int Generic = 1; const int LocalMachine = 2; const int NotFound = 1168;
    public static void Put(string target, string secret) {
      byte[] blob = Encoding.UTF8.GetBytes(secret);
      CREDENTIAL c = new CREDENTIAL();
      c.Type = Generic; c.TargetName = target; c.UserName = "troupe"; c.Persist = LocalMachine;
      c.CredentialBlobSize = blob.Length; c.CredentialBlob = Marshal.AllocHGlobal(blob.Length);
      try {
        Marshal.Copy(blob, 0, c.CredentialBlob, blob.Length);
        if (!CredWriteW(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      } finally { Marshal.FreeHGlobal(c.CredentialBlob); }
    }
    public static string Get(string target) {
      IntPtr p;
      if (!CredReadW(target, Generic, 0, out p)) {
        int e = Marshal.GetLastWin32Error();
        if (e == NotFound) return null;
        throw new System.ComponentModel.Win32Exception(e);
      }
      try {
        CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
        byte[] blob = new byte[c.CredentialBlobSize];
        Marshal.Copy(c.CredentialBlob, blob, 0, blob.Length);
        return Encoding.UTF8.GetString(blob);
      } finally { CredFree(p); }
    }
    public static void Delete(string target) {
      if (!CredDeleteW(target, Generic, 0)) {
        int e = Marshal.GetLastWin32Error();
        if (e != NotFound) throw new System.ComponentModel.Win32Exception(e);
      }
    }
  }
  '@
    $target = $env:TROUPE_KEYRING_ENTRY
    switch ($env:TROUPE_KEYRING_OP) {
      'put' { [TroupeKeyring]::Put($target, $env:TROUPE_KEYRING_VALUE); 'ok' }
      'delete' { [TroupeKeyring]::Delete($target); 'ok' }
      'get' {
        $value = [TroupeKeyring]::Get($target)
        if ($null -eq $value) { 'none' } else { 'value:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)) }
      }
    }
  } catch {
    'error:' + $_.Exception.Message
    exit 1
  }
  """

  defp windows(op, entry, value) do
    encoded =
      @windows_script
      |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
      |> Base.encode64()

    env = [{"TROUPE_KEYRING_OP", Atom.to_string(op)}, {"TROUPE_KEYRING_ENTRY", entry}] ++ value_env(value)
    args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded]

    with {:ok, output, status} <- exec("powershell", args, env) do
      lines = output |> String.split(["\r\n", "\n"], trim: true) |> Enum.map(&String.trim/1)
      windows_answer(op, Enum.find(lines, &answer_line?/1), status)
    end
  end

  defp answer_line?(line),
    do: line in ["ok", "none"] or String.starts_with?(line, ["value:", "error:"])

  defp windows_answer(:get, "none", 0), do: :none

  defp windows_answer(:get, "value:" <> encoded, 0) do
    case Base.decode64(encoded) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :unreadable}
    end
  end

  defp windows_answer(_op, "ok", 0), do: :ok
  defp windows_answer(_op, "error:" <> reason, _status), do: {:error, {:keyring, reason}}
  defp windows_answer(_op, other, status), do: {:error, {:keyring, "exit #{status}: #{inspect(other)}"}}

  # -- macOS ---------------------------------------------------------------------

  defp mac(op, entry, value) do
    {service, account} = split(entry)
    env = [{"TROUPE_KEYRING_SERVICE_NAME", service}, {"TROUPE_KEYRING_ACCOUNT", account}] ++ value_env(value)

    case op do
      :get ->
        script = ~S(security find-generic-password -s "$TROUPE_KEYRING_SERVICE_NAME" -a "$TROUPE_KEYRING_ACCOUNT" -w)

        case exec("sh", ["-c", script], env) do
          {:ok, output, 0} -> {:ok, String.trim_trailing(output, "\n")}
          {:ok, _output, 44} -> :none
          other -> failed(other)
        end

      :put ->
        script =
          ~S(printf 'add-generic-password -U -s %s -a %s -w %s\n' "$TROUPE_KEYRING_SERVICE_NAME" "$TROUPE_KEYRING_ACCOUNT" "$TROUPE_KEYRING_VALUE" | security -i)

        status_only(exec("sh", ["-c", script], env))

      :delete ->
        script = ~S(security delete-generic-password -s "$TROUPE_KEYRING_SERVICE_NAME" -a "$TROUPE_KEYRING_ACCOUNT")

        case exec("sh", ["-c", script], env) do
          {:ok, _output, status} when status in [0, 44] -> :ok
          other -> failed(other)
        end
    end
  end

  # -- the Secret Service -----------------------------------------------------------

  @attributes ~S(service "$TROUPE_KEYRING_SERVICE_NAME" account "$TROUPE_KEYRING_ACCOUNT")

  defp secret_tool(op, entry, value) do
    if Troupe.Executable.find("secret-tool") == nil do
      {:error, :unavailable}
    else
      {service, account} = split(entry)
      env = [{"TROUPE_KEYRING_SERVICE_NAME", service}, {"TROUPE_KEYRING_ACCOUNT", account}] ++ value_env(value)
      secret_tool(op, env)
    end
  end

  defp secret_tool(:get, env) do
    case exec("sh", ["-c", "secret-tool lookup " <> @attributes], env) do
      {:ok, output, 0} -> {:ok, String.trim_trailing(output, "\n")}
      {:ok, "", 1} -> :none
      other -> failed(other)
    end
  end

  defp secret_tool(:put, env) do
    script = ~S(printf '%s' "$TROUPE_KEYRING_VALUE" | secret-tool store --label="Troupe" ) <> @attributes
    status_only(exec("sh", ["-c", script], env))
  end

  defp secret_tool(:delete, env),
    do: status_only(exec("sh", ["-c", "secret-tool clear " <> @attributes], env))

  # -- running the tool ---------------------------------------------------------------

  defp split(entry) do
    case String.split(entry, "/", parts: 2) do
      [service, account] -> {service, account}
      [account] -> {"troupe", account}
    end
  end

  defp value_env(nil), do: []
  defp value_env(value), do: [{"TROUPE_KEYRING_VALUE", value}]

  defp status_only({:ok, _output, 0}), do: :ok
  defp status_only(other), do: failed(other)

  defp failed({:ok, output, status}), do: {:error, {:keyring, "exit #{status}: #{String.trim(output)}"}}
  defp failed({:error, reason}), do: {:error, reason}

  defp exec(program, args, env) do
    case Troupe.Executable.find(program) do
      nil ->
        {:error, :unavailable}

      exe ->
        env = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args,
            env: env
          ])

        collect(port, [])
    end
  rescue
    error -> {:error, {:keyring, Exception.message(error)}}
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, [output, data])
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(output), status}
    after
      @timeout_ms ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
