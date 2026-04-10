defmodule KbaseBotTest do
  use ExUnit.Case
  doctest KbaseBot

  test "greets the world" do
    assert KbaseBot.hello() == :world
  end
end
