defmodule BonsekiTest do
  use ExUnit.Case
  doctest Bonseki

  test "greets the world" do
    assert Bonseki.hello() == :world
  end
end
