defmodule Troupe.Test.RaisingTool do
  @moduledoc """
  A tool that raises. Installed through `:extra_tools` to prove that a tool blowing
  up becomes an error result rather than taking the agent with it.
  """

  @behaviour Troupe.Tool

  @impl Troupe.Tool
  def name, do: "boom"

  @impl Troupe.Tool
  def description, do: "Raises. Test only."

  @impl Troupe.Tool
  def schema, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(_args, _ctx), do: raise("tool exploded on purpose")
end

defmodule Troupe.Test.ExitingTool do
  @moduledoc "A tool whose process exits abnormally without returning."

  @behaviour Troupe.Tool

  @impl Troupe.Tool
  def name, do: "vanish"

  @impl Troupe.Tool
  def description, do: "Exits. Test only."

  @impl Troupe.Tool
  def schema, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(_args, _ctx), do: exit(:deliberate)
end

defmodule Troupe.Test.AskingTool do
  @moduledoc "A tool that always needs approval, so approval flow can be tested alone."

  @behaviour Troupe.Tool

  @impl Troupe.Tool
  def name, do: "needs_approval"

  @impl Troupe.Tool
  def description, do: "Requires approval. Test only."

  @impl Troupe.Tool
  def schema do
    %{"type" => "object", "properties" => %{"note" => %{"type" => "string"}}, "required" => []}
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def run(args, _ctx), do: {:ok, "approved: #{Map.get(args, "note", "")}"}
end

defmodule Troupe.Test.CountingTool do
  @moduledoc """
  A tool that records every invocation in a file, so a test can prove a completed
  call was not executed twice across a crash and replay.
  """

  @behaviour Troupe.Tool

  @impl Troupe.Tool
  def name, do: "count"

  @impl Troupe.Tool
  def description, do: "Appends to a file. Test only."

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "mark" => %{"type" => "string"},
        "delay_ms" => %{"type" => "integer"}
      },
      "required" => ["path", "mark"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, resolved} <- Troupe.Workspace.resolve(ctx.workspace, Map.fetch!(args, "path")) do
      if delay = args["delay_ms"], do: Process.sleep(delay)
      File.write!(resolved, Map.fetch!(args, "mark") <> "\n", [:append])
      {:ok, "recorded"}
    end
  end
end
