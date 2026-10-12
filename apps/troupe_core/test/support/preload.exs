defmodule Troupe.Test.Preload do
  @moduledoc """
  Every module of the build the suite runs, loaded before the first test, as a release
  loads them all at boot.

  `mix test` loads a module the first time something calls it, through the one code
  server, which finds and reads the file and only then turns to the next caller. A process
  on a deadline that is the first to call a module waits for that read, and for every read
  queued in front of it. On a fast disk that is nothing. With the build on a slow one (a
  Windows drive reached from WSL, about 30 ms a file while other suites run) loading the
  core suite's modules one after another takes over a minute, and tests time out
  together: a scripted turn past `await_event`'s five seconds, a Finch pool's first
  checkout past its own five ("excess queuing"). Read here in parallel, outside the code
  server, it takes a few seconds, once.

  A module's file is its application's `ebin`, as the build wrote it; a protocol the build
  consolidated is left to load from where `mix test` put the consolidated one.
  """

  @spec run() :: :ok
  def run do
    build = Mix.Project.build_path()
    consolidated = consolidated()

    for {app, _description, _version} <- Application.started_applications(),
        dir = :code.lib_dir(app),
        is_list(dir),
        String.starts_with?(List.to_string(dir), build),
        {:ok, modules} <- [:application.get_key(app, :modules)],
        module <- modules,
        not :erlang.module_loaded(module),
        file = Path.join([List.to_string(dir), "ebin", Atom.to_string(module) <> ".beam"]),
        not MapSet.member?(consolidated, Path.basename(file)) do
      {module, file}
    end
    |> Task.async_stream(&read/1, max_concurrency: 32, ordered: false, timeout: :infinity)
    |> Enum.each(fn
      {:ok, {module, file, {:ok, binary}}} ->
        :code.load_binary(module, String.to_charlist(file), binary)

      {:ok, _unreadable} ->
        :ok
    end)
  end

  defp read({module, file}), do: {module, file, :file.read_file(file, [:raw])}

  defp consolidated do
    case :file.list_dir(Mix.Project.consolidation_path()) do
      {:ok, names} -> MapSet.new(names, &List.to_string/1)
      {:error, _none} -> MapSet.new()
    end
  end
end
