defmodule Troupe.Plane.Artifacts.Mermaid do
  @moduledoc """
  A Mermaid flowchart in a Markdown artifact, drawn as a static SVG on the server (#62), so
  the page needs no diagramming script to show it.

  Flowcharts only (`graph` or `flowchart`, in any of the four directions): nodes with the
  common shapes (`[box]`, `(rounded)`, `([stadium])`, `((circle))`, `{decision}`, and the rest
  drawn as boxes), edges `-->`, `---`, `-.->`, `==>` and `<-->`, with a label as `-->|text|` or
  `-- text -->`, chains (`a --> b --> c`) and `&` (`a & b --> c`). Subgraphs are drawn without
  their frame, and styling statements are ignored. Laid out in ranks by longest path from
  the sources, in the order the text first names each node. Any other diagram is
  `:unsupported`, and the page shows its source.

  Every label is escaped; the SVG has no script, no link and no style of its own beyond the
  classes the document's stylesheet colours.
  """

  alias Troupe.Plane.Artifacts.Markdown

  @edge ~r/\s*(<-->|-\.->|-\.-|==>|===|-->|---|--\s+[^-|>][^>]*?\s+-->|==\s+[^=|>][^>]*?\s+==>)\s*(?:\|([^|]*)\|)?\s*/

  @gap 48
  @rank_gap 64
  @height 40

  @doc "The SVG for `source`, or `:unsupported` for anything but a flowchart."
  @spec render(String.t()) :: {:ok, String.t()} | :unsupported
  def render(source) do
    lines =
      source
      |> String.split(["\n", ";"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "%%")))

    with [head | statements] <- lines,
         {:ok, direction} <- direction(head),
         {nodes, edges} when map_size(nodes) > 0 and map_size(nodes) <= 200 <- parse(statements) do
      {:ok, draw(nodes, edges, direction)}
    else
      _ -> :unsupported
    end
  end

  # A bare `graph` is top to bottom, as `TD` and `TB` both are.
  defp direction(head) do
    case Regex.run(~r/\A(?:graph|flowchart)(?:\s+(TD|TB|BT|LR|RL))?\s*\z/i, head) do
      [_] -> {:ok, "TD"}
      [_, direction] -> {:ok, String.upcase(direction)}
      nil -> :unsupported
    end
  end

  # -- parsing ------------------------------------------------------------------------

  defp parse(statements) do
    Enum.reduce(statements, {%{}, []}, fn statement, {nodes, edges} ->
      cond do
        statement =~ ~r/\A(classDef|class|style|linkStyle|click|direction)\b/ -> {nodes, edges}
        statement =~ ~r/\Asubgraph\b/ -> {nodes, edges}
        statement == "end" -> {nodes, edges}
        true -> statement(statement, nodes, edges)
      end
    end)
    |> then(fn {nodes, edges} -> {nodes, Enum.reverse(edges)} end)
  end

  defp statement(statement, nodes, edges) do
    parts = Regex.split(@edge, statement, include_captures: true)

    {groups, ops} = Enum.split_with(Enum.with_index(parts), fn {_part, i} -> rem(i, 2) == 0 end)
    groups = Enum.map(groups, fn {part, _} -> part end)
    ops = Enum.map(ops, fn {op, _} -> op end)

    {nodes, ids} =
      Enum.map_reduce(groups, nodes, fn group, nodes ->
        group
        |> String.split(~r/\s*&\s*/)
        |> Enum.map_reduce(nodes, &node/2)
        |> then(fn {ids, nodes} -> {Enum.reject(ids, &is_nil/1), nodes} end)
      end)
      |> then(fn {ids, nodes} -> {nodes, ids} end)

    edges =
      ops
      |> Enum.with_index()
      |> Enum.reduce(edges, fn {op, i}, edges ->
        {kind, label} = operator(op)

        for from <- Enum.at(ids, i, []), to <- Enum.at(ids, i + 1, []), reduce: edges do
          edges -> [%{from: from, to: to, kind: kind, label: label} | edges]
        end
      end)

    {nodes, edges}
  end

  defp node(text, nodes) do
    case Regex.run(~r/\A([A-Za-z0-9_][\w.-]*)\s*(.*)\z/s, String.trim(text)) do
      [_, id, rest] ->
        {shape, label} = shape(String.trim(rest))
        known = Map.get(nodes, id)

        node =
          cond do
            known && label == nil -> known
            known -> %{known | shape: shape, label: label}
            true -> %{id: id, shape: shape, label: label || id, order: map_size(nodes)}
          end

        {id, Map.put(nodes, id, node)}

      nil ->
        {nil, nodes}
    end
  end

  @shapes [
    {~r/\A\(\((.*)\)\)\z/s, :circle},
    {~r/\A\(\[(.*)\]\)\z/s, :stadium},
    {~r/\A\[\[(.*)\]\]\z/s, :box},
    {~r/\A\[\((.*)\)\]\z/s, :box},
    {~r/\A\{\{(.*)\}\}\z/s, :box},
    {~r/\A\[(.*)\]\z/s, :box},
    {~r/\A\((.*)\)\z/s, :rounded},
    {~r/\A\{(.*)\}\z/s, :diamond},
    {~r/\A>(.*)\]\z/s, :box}
  ]

  defp shape(""), do: {:box, nil}

  defp shape(rest) do
    Enum.find_value(@shapes, {:box, rest}, fn {pattern, shape} ->
      case Regex.run(pattern, rest) do
        [_, label] -> {shape, clean(label)}
        nil -> nil
      end
    end)
  end

  defp clean(label) do
    label
    |> String.trim()
    |> String.trim("\"")
    |> String.replace(~r/<br\s*\/?>/i, " ")
  end

  defp operator(op) do
    op = String.trim(op)
    label = Regex.run(~r/\|([^|]*)\|/, op) |> then(&(&1 && clean(Enum.at(&1, 1))))
    core = String.replace(op, ~r/\|[^|]*\|/, "") |> String.trim()

    # An inline label's text is the label's: the edge is what closes it, so a dot in
    # `-- v1.2 -->` does not make it dotted.
    {inline_label, core} =
      case Regex.run(~r/\A(?:--|==)\s+(.+?)\s+(-->|==>)\z/, core) do
        [_, text, closing] -> {clean(text), closing}
        nil -> {nil, core}
      end

    {edge_kind(core), label || inline_label}
  end

  defp edge_kind("<-->" <> _), do: :both
  defp edge_kind("==" <> _), do: :thick

  defp edge_kind(core) do
    case {String.contains?(core, "."), String.ends_with?(core, ">")} do
      {true, true} -> :dotted
      {true, false} -> :dotted_line
      {false, true} -> :arrow
      {false, false} -> :line
    end
  end

  # -- layout -------------------------------------------------------------------------

  defp draw(nodes, edges, direction) do
    ranks = ranks(nodes, edges)
    horizontal = direction in ["LR", "RL"]

    sized =
      Map.new(nodes, fn {id, node} ->
        width = max(64, 8 * String.length(node.label) + 32)
        width = if node.shape == :diamond, do: width + 24, else: width
        {id, Map.merge(node, %{width: width, height: @height, rank: Map.fetch!(ranks, id)})}
      end)

    layers =
      sized
      |> Map.values()
      |> Enum.group_by(& &1.rank)
      |> Map.new(fn {rank, layer} -> {rank, Enum.sort_by(layer, & &1.order)} end)

    # Each layer's breadth, across the direction of flow, and the widest.
    breadth = fn layer ->
      Enum.sum(Enum.map(layer, &if(horizontal, do: &1.height, else: &1.width))) +
        @gap * (length(layer) - 1)
    end

    widest = layers |> Map.values() |> Enum.map(breadth) |> Enum.max()
    depth = fn node -> if horizontal, do: node.width, else: node.height end

    rank_depth =
      Map.new(layers, fn {rank, layer} -> {rank, layer |> Enum.map(depth) |> Enum.max()} end)

    max_rank = layers |> Map.keys() |> Enum.max()

    offsets =
      Enum.reduce(0..max_rank, {%{}, 16}, fn rank, {acc, at} ->
        {Map.put(acc, rank, at), at + Map.get(rank_depth, rank, 0) + @rank_gap}
      end)
      |> elem(0)

    place = fn node, rank, at ->
      along = Map.fetch!(offsets, rank) + (Map.fetch!(rank_depth, rank) - depth.(node)) / 2
      {x, y} = if horizontal, do: {along, at}, else: {at, along}

      {Map.merge(node, %{x: x, y: y}),
       at + if(horizontal, do: node.height, else: node.width) + @gap}
    end

    placed =
      Enum.reduce(layers, %{}, fn {rank, layer}, acc ->
        layer
        |> Enum.map_reduce(16 + (widest - breadth.(layer)) / 2, &place.(&1, rank, &2))
        |> elem(0)
        |> Enum.reduce(acc, &Map.put(&2, &1.id, &1))
      end)

    total_along = Map.fetch!(offsets, max_rank) + Map.fetch!(rank_depth, max_rank) + 16

    {width, height} =
      if horizontal, do: {total_along, widest + 32}, else: {widest + 32, total_along}

    placed = flip(placed, direction, width, height)

    svg(placed, edges, round(width), round(height))
  end

  defp flip(placed, "BT", _width, height),
    do: Map.new(placed, fn {id, n} -> {id, %{n | y: height - n.y - n.height}} end)

  defp flip(placed, "RL", width, _height),
    do: Map.new(placed, fn {id, n} -> {id, %{n | x: width - n.x - n.width}} end)

  defp flip(placed, _direction, _width, _height), do: placed

  # Longest path from a source, over the edges that do not close a cycle.
  defp ranks(nodes, edges) do
    order = nodes |> Map.values() |> Enum.sort_by(& &1.order) |> Enum.map(& &1.id)
    out = Enum.group_by(edges, & &1.from, & &1.to)

    {forward, _seen} =
      Enum.reduce(order, {[], MapSet.new()}, fn id, acc -> walk(id, out, MapSet.new(), acc) end)

    Enum.reduce(1..max(length(order), 1), Map.new(order, &{&1, 0}), fn _, ranks ->
      Enum.reduce(forward, ranks, &lengthen/2)
    end)
  end

  defp lengthen({from, to}, ranks), do: Map.update!(ranks, to, &max(&1, ranks[from] + 1))

  defp walk(id, out, path, {forward, seen}) do
    if MapSet.member?(seen, id) do
      {forward, seen}
    else
      path = MapSet.put(path, id)

      Enum.reduce(
        Map.get(out, id, []),
        {forward, MapSet.put(seen, id)},
        &step(id, &1, out, path, &2)
      )
    end
  end

  # An edge back into the path being walked closes a cycle and is left out of the ranking.
  defp step(id, to, out, path, {forward, seen}) do
    if MapSet.member?(path, to),
      do: {forward, seen},
      else: walk(to, out, path, {[{id, to} | forward], seen})
  end

  # -- drawing ------------------------------------------------------------------------

  defp svg(nodes, edges, width, height) do
    title = "A flowchart of #{map_size(nodes)} steps"

    [
      ~s(<svg class="mermaid" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" aria-label="#{title}">),
      ~s(<defs><marker id="m-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="m-head"/></marker></defs>),
      Enum.map(edges, &edge(&1, nodes)),
      nodes |> Map.values() |> Enum.sort_by(& &1.order) |> Enum.map(&shape_svg/1),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  defp edge(%{from: from, to: to} = edge, nodes) do
    a = Map.fetch!(nodes, from)
    b = Map.fetch!(nodes, to)
    {ax, ay} = centre(a)
    {bx, by} = centre(b)
    {x1, y1} = border(a, bx, by)
    {x2, y2} = border(b, ax, ay)

    ~s(<line class="#{edge_class(edge.kind)}" x1="#{n(x1)}" y1="#{n(y1)}" x2="#{n(x2)}" y2="#{n(y2)}"#{markers(edge.kind)}/>) <>
      edge_label(edge.label, (x1 + x2) / 2, (y1 + y2) / 2)
  end

  defp edge_class(kind) when kind in [:dotted, :dotted_line], do: "m-edge m-dotted"
  defp edge_class(:thick), do: "m-edge m-thick"
  defp edge_class(_kind), do: "m-edge"

  defp markers(:both), do: ~s{ marker-end="url(#m-arrow)" marker-start="url(#m-arrow)"}
  defp markers(kind) when kind in [:arrow, :dotted, :thick], do: ~s{ marker-end="url(#m-arrow)"}
  defp markers(_kind), do: ""

  defp edge_label(label, mx, my) when is_binary(label) and label != "" do
    w = 7 * String.length(label) + 12

    ~s(<rect class="m-label-box" x="#{n(mx - w / 2)}" y="#{n(my - 10)}" width="#{n(w)}" height="20" rx="4"/>) <>
      ~s(<text class="m-label" x="#{n(mx)}" y="#{n(my + 4)}" text-anchor="middle">#{Markdown.escape(label)}</text>)
  end

  defp edge_label(_label, _mx, _my), do: ""

  defp shape_svg(node) do
    {cx, cy} = centre(node)
    %{x: x, y: y, width: w, height: h} = node

    outline =
      case node.shape do
        :rounded ->
          ~s(<rect class="m-node" x="#{n(x)}" y="#{n(y)}" width="#{w}" height="#{h}" rx="10"/>)

        :stadium ->
          ~s(<rect class="m-node" x="#{n(x)}" y="#{n(y)}" width="#{w}" height="#{h}" rx="#{div(h, 2)}"/>)

        :circle ->
          ~s(<ellipse class="m-node" cx="#{n(cx)}" cy="#{n(cy)}" rx="#{n(w / 2)}" ry="#{n(h / 2 + 4)}"/>)

        :diamond ->
          ~s(<polygon class="m-node" points="#{n(cx)},#{n(y - 6)} #{n(x + w)},#{n(cy)} #{n(cx)},#{n(y + h + 6)} #{n(x)},#{n(cy)}"/>)

        _box ->
          ~s(<rect class="m-node" x="#{n(x)}" y="#{n(y)}" width="#{w}" height="#{h}" rx="3"/>)
      end

    outline <>
      ~s(<text class="m-text" x="#{n(cx)}" y="#{n(cy + 5)}" text-anchor="middle">#{Markdown.escape(node.label)}</text>)
  end

  defp centre(node), do: {node.x + node.width / 2, node.y + node.height / 2}

  # Where the line from the node's centre towards (tx, ty) leaves its box.
  defp border(node, tx, ty) do
    {cx, cy} = centre(node)
    dx = tx - cx
    dy = ty - cy

    if dx == 0 and dy == 0 do
      {cx, cy}
    else
      hw = node.width / 2
      hh = node.height / 2
      scale = 1 / max(abs(dx) / hw, abs(dy) / hh)
      {cx + dx * scale, cy + dy * scale}
    end
  end

  defp n(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp n(value), do: Integer.to_string(value)
end
