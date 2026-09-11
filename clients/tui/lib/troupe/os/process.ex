defmodule Troupe.OS.Process do
  @moduledoc """
  The only way the harness starts OS processes. Every command runs under
  `reaper`; the Port is owned by the calling process, so if the caller dies for
  any reason the pipe closes and reaper kills the whole process tree.
  """

  @type result :: {:ok, String.t(), non_neg_integer()} | {:error, :timeout, String.t()}

  @default_timeout 120_000
  @default_max_output 200_000

  @doc """
  Runs `cmd` with `args` under reaper. Options: `:cd`, `:timeout_ms`, `:env`
  (list of `{name, value}` strings), `:max_output` (bytes kept), `:on_pid`
  (fun receiving the reaper's OS pid).
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    reaper = Troupe.Reaper.path!()
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    max_output = Keyword.get(opts, :max_output, @default_max_output)

    exe = System.find_executable(cmd) || cmd

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :hide, args: [exe | args]] ++
        cd_opt(opts[:cd]) ++ env_opt(opts[:env])

    port = Port.open({:spawn_executable, reaper}, port_opts)

    case Keyword.get(opts, :on_pid) do
      nil -> :ok
      fun -> fun.(port_os_pid(port))
    end

    collect(port, [], 0, max_output, timeout)
  end

  @doc "Runs a shell command string with the platform shell."
  @spec shell(String.t(), keyword()) :: result()
  def shell(command, opts \\ []) when is_binary(command) do
    {exe, args} = shell_command(command)
    run(exe, args, opts)
  end

  @doc "Returns `{shell_name, description}` for the tool description."
  @spec shell_info() :: {String.t(), String.t()}
  def shell_info do
    {exe, _} = shell_command("true")
    os = :os.type() |> elem(1) |> to_string()
    {Path.basename(exe), "#{os} (#{arch()}), shell: #{Path.basename(exe)}"}
  end

  defp arch, do: to_string(:erlang.system_info(:system_architecture))

  defp shell_command(command) do
    case :os.type() do
      {:win32, _} -> windows_shell(command)
      _ -> {unix_shell(), ["-c", command]}
    end
  end

  # bash on Linux and macOS; a clean Alpine has only sh, so fall back rather than fail every command.
  defp unix_shell, do: if(System.find_executable("bash"), do: "bash", else: "sh")

  defp windows_shell(command) do
    git_bash =
      [System.get_env("ProgramFiles"), System.get_env("ProgramFiles(x86)")]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(
        &[
          Path.join([&1, "Git", "bin", "bash.exe"]),
          Path.join([&1, "Git", "usr", "bin", "bash.exe"])
        ]
      )
      |> Enum.find(&File.exists?/1)

    cond do
      git_bash ->
        {git_bash, ["-c", command]}

      System.find_executable("pwsh") ->
        {"pwsh", ["-NoProfile", "-NonInteractive", "-Command", command]}

      true ->
        {"powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command]}
    end
  end

  defp cd_opt(nil), do: []
  defp cd_opt(dir), do: [cd: to_charlist(dir)]

  defp env_opt(nil), do: []
  defp env_opt(env), do: [env: Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)]

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp collect(port, acc, size, max_output, timeout) do
    receive do
      {^port, {:data, data}} ->
        {acc, size} = append(acc, size, data, max_output)
        collect(port, acc, size, max_output, timeout)

      {^port, {:exit_status, status}} ->
        {:ok, finish(acc, size, max_output), status}
    after
      timeout ->
        # Closing the port sends EOF to reaper, which kills the tree.
        safe_close(port)
        {:error, :timeout, finish(acc, size, max_output)}
    end
  end

  defp append(acc, size, data, max_output) when size >= max_output,
    do: {acc, size + byte_size(data)}

  defp append(acc, size, data, max_output) do
    room = max_output - size

    if byte_size(data) > room do
      {[binary_part(data, 0, room) | acc], size + byte_size(data)}
    else
      {[data | acc], size + byte_size(data)}
    end
  end

  defp finish(acc, size, max_output) do
    out = acc |> Enum.reverse() |> IO.iodata_to_binary()

    if size > max_output do
      out <> "\n[output truncated: #{size - max_output} more bytes]"
    else
      out
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
