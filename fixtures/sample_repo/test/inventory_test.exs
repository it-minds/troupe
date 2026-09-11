defmodule InventoryTest do
  use ExUnit.Case, async: true

  @items [
    %{sku: "widget", quantity: 10},
    %{sku: "gizmo", quantity: 3},
    %{sku: "sprocket", quantity: 0}
  ]

  test "total sums every quantity" do
    assert Inventory.total(@items) == 13
  end

  test "below_threshold includes items exactly at the threshold" do
    assert Inventory.below_threshold(@items, 3) == [
             %{sku: "gizmo", quantity: 3},
             %{sku: "sprocket", quantity: 0}
           ]
  end

  test "below_threshold excludes items above the threshold" do
    assert Inventory.below_threshold(@items, 1) == [%{sku: "sprocket", quantity: 0}]
  end
end
