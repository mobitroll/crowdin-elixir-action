defmodule CrowdinElixirActionTest do
  use ExUnit.Case
  doctest CrowdinElixirAction

  test "greets the world" do
    assert CrowdinElixirAction.hello() == :world
  end
end
