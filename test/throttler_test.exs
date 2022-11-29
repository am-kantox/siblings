defmodule Siblings.Test.Throttler do
  use ExUnit.Case, async: true

  doctest Siblings.Throttler
  doctest Siblings.Throttler.Producer
  doctest Siblings.Throttler.Consumer

  setup do
    %{siblings: start_supervised!(Siblings.child_spec(name: SiblingsThrottler))}
  end

  test "Throttling" do
    assert %Siblings.Throttler{
             args: [value: 42],
             result: :ok,
             payload: nil
           } = Siblings.Throttler.call(SiblingsThrottler, 42)
  end

  test "Throttling (multiple call)" do
    assert [
             %Siblings.Throttler{args: [value: 1]},
             %Siblings.Throttler{args: [value: 2]},
             %Siblings.Throttler{args: [value: 3]}
           ] = Siblings.Throttler.call(SiblingsThrottler, [1, 2, 3])
  end

  test "Throttling (function)" do
    assert %Siblings.Throttler{result: 84, payload: :ok} =
             Siblings.Throttler.call(SiblingsThrottler, %Siblings.Throttler{
               fun: &(&1[:value] * 2),
               args: [value: 42],
               payload: :ok
             })
  end
end
