defmodule Siblings.Throttler.Producer do
  @moduledoc false
  use GenStage

  alias Siblings.Throttler

  def start_link(initial \\ []),
    do: GenStage.start_link(__MODULE__, initial)

  @spec init([Throttler.throttlee()]) :: {:producer, [Throttler.throttlee()]}
  @impl GenStage
  def init(initial) when is_list(initial),
    do: {:producer, normalize(nil, initial)}

  @impl GenStage
  def handle_demand(demand, initial) when demand > 0 do
    {head, tail} = Enum.split(initial, demand)
    {:noreply, head, tail}
  end

  @impl GenStage
  def handle_call({:add, items}, from, state) when is_list(items),
    do: {:noreply, [], state ++ normalize(from, items)}

  def handle_call({:add, item}, from, state),
    do: handle_call({:add, [item]}, from, state)

  defp normalize(from, items) do
    Enum.map(items, fn
      %Throttler{} = t ->
        %Throttler{t | from: from}

      {fun, args} when is_function(fun, 1) and is_list(args) ->
        %Throttler{from: from, fun: fun, args: args}

      value ->
        %Throttler{from: from, fun: &Throttler.debug/1, args: [value: value]}
    end)
  end
end
