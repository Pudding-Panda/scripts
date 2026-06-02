defmodule DevtimeServerTest do
  use ExUnit.Case
  doctest DevtimeServer

  test "greets the world" do
    assert DevtimeServer.hello() == :world
  end
end
