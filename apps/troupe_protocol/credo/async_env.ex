defmodule Troupe.Credo.AsyncEnv do
  @moduledoc """
  A test module that runs `async: true` sets no environment variable another module can
  read. The process environment is the VM's, so a `HOME`, a `TROUPE_*_HOME` or a `PATH`
  one async test sets is the home every other test running beside it reads, and the
  failure lands in that other test, now and then. Such a module is `async: false`, or
  gives each test homes of its own through options rather than the environment.

  What an async module may set is a variable named `TROUPE_TEST_...`: by its name it is
  that test's own, read by nothing but the test that set it. The variable is given as a
  literal, or as a name the module binds to one (`var = "TROUPE_TEST_X_\#{n}"`). A
  deliberate exception says why beside a `# credo:disable-for-next-line` naming this check.

  Loaded by the configurations that list it (`requires`), not compiled into any app; it
  runs on test files only.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `System.put_env/2` and `System.delete_env/1` change the environment of the whole
      VM. In a module that runs `async: true`, every test running at the same moment sees
      the change, and one that reads a home from the environment reads this test's. Make
      the module `async: false`, give the code under test its homes as options, or set
      only a variable named `TROUPE_TEST_...` that nothing else reads.
      """
    ]

  @own "TROUPE_TEST_"

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    source = SourceFile.source(source_file)
    Credo.Code.prewalk(source_file, &walk(&1, &2, source), ctx).issues
  end

  defp walk({:defmodule, _meta, [_name, [do: body]]} = ast, ctx, source) do
    if async?(body) do
      {ast, Enum.reduce(env_calls(body), ctx, &check_call(&1, &2, source))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx, _source), do: {ast, ctx}

  # `use ExUnit.Case, async: true`, or any case template used with it.
  defp async?(body) do
    body
    |> own_nodes()
    |> Enum.any?(fn
      {:use, _, [_template, opts]} when is_list(opts) -> Keyword.get(opts, :async) == true
      _ -> false
    end)
  end

  defp env_calls(body) do
    body
    |> own_nodes()
    |> Enum.filter(
      &match?(
        {{:., _, [{:__aliases__, _, [:System]}, f]}, _, _} when f in [:put_env, :delete_env],
        &1
      )
    )
  end

  # Every node of a module's body, but not those of a module nested in it: that one is
  # walked on its own, with its own `async`.
  defp own_nodes({:defmodule, _, _}), do: []
  defp own_nodes({form, _, args} = node), do: [node | own_nodes(form) ++ own_nodes(args)]
  defp own_nodes({left, right}), do: own_nodes(left) ++ own_nodes(right)
  defp own_nodes(list) when is_list(list), do: Enum.flat_map(list, &own_nodes/1)
  defp own_nodes(_leaf), do: []

  defp check_call({{:., _, [_, fun]}, meta, [var | _]}, ctx, source) do
    if own?(var, source), do: ctx, else: put_issue(ctx, issue(ctx, meta, fun))
  end

  defp check_call({{:., _, [_, fun]}, meta, _args}, ctx, _source),
    do: put_issue(ctx, issue(ctx, meta, fun))

  defp own?(name, _source) when is_binary(name), do: String.starts_with?(name, @own)

  defp own?({:<<>>, _, [prefix | _]}, _source) when is_binary(prefix),
    do: String.starts_with?(prefix, @own)

  # A name, or a field of the test's context: own when the module binds that name to one.
  defp own?({name, _, context}, source) when is_atom(name) and is_atom(context),
    do: bound_to_own?(name, source)

  defp own?({{:., _, [_map, field]}, _, []}, source) when is_atom(field),
    do: bound_to_own?(field, source)

  defp own?(_var, _source), do: false

  defp bound_to_own?(name, source) do
    Regex.match?(~r/\b#{Regex.escape(Atom.to_string(name))}\s*(=|:)\s*"#{@own}/, source)
  end

  defp issue(ctx, meta, fun) do
    format_issue(ctx,
      message:
        "System.#{fun} in an async: true test module: every test beside it reads that " <>
          "environment. Make the module async: false, pass homes as options, or set only " <>
          "a TROUPE_TEST_ variable of the test's own.",
      trigger: "System.#{fun}",
      line_no: meta[:line]
    )
  end
end
