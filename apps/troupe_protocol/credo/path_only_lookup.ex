defmodule Troupe.Credo.PathOnlyLookup do
  @moduledoc """
  A program Troupe starts by name is found by `Troupe.Executable`, on `PATH` alone
  (Decision 846). `System.find_executable/1` and `:os.find_executable/1,2` look in the
  current directory first on Windows, and the daemon's or the TUI's is wherever it was
  started, often a repository. This fails on either in the files a configuration gives it
  with credo's own `files:` parameter: `apps/*/lib/` in the umbrella's `.credo.exs`, `lib/`
  in the TUI's. Tests may use them.

  Loaded by those configurations (`requires`), not compiled into any app.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      On Windows `System.find_executable/1` and `:os.find_executable/1,2` look in the
      current directory before `PATH`, so a repository carrying `rg.bat` or `pwsh.bat`
      has it run in place of the real program. Look a program up with
      `Troupe.Executable.find/2`, or `Troupe.Executable.resolve/3` for a command as a
      person wrote it (in the TUI, `Troupe.OS.Process.executable/2`).
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  defp walk({{:., _, [{:__aliases__, _, [:System]}, :find_executable]}, meta, _args} = ast, ctx),
    do: {ast, put_issue(ctx, issue(ctx, meta, "System.find_executable"))}

  defp walk({{:., _, [:os, :find_executable]}, meta, _args} = ast, ctx),
    do: {ast, put_issue(ctx, issue(ctx, meta, ":os.find_executable"))}

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue(ctx, meta, trigger) do
    format_issue(ctx,
      message:
        "#{trigger} looks in the current directory first on Windows: " <>
          "use Troupe.Executable (Decision 846).",
      trigger: trigger,
      line_no: meta[:line]
    )
  end
end
