defmodule Siblings.Throttler do
  @moduledoc """
  The internal definition of the call to throttle. The result will be send to
  `from` as `{:throttler, result}`.
  """

  @type t :: %{
    __struct__: Siblings.Throttler,
    from: pid(),
    fun: function()
  }

  defstruct ~w|from fun|a

  defmodule Producer do
    @moduledoc false
    use GenStage

    @spec init([Siblings.Throttler.t()]) :: {:producer, [Siblings.Throttler.t()]}
    def init(initial) when is_list(initial), do: {:producer, initial}

    def handle_demand(demand, initial) when demand > 0 do
      {head, tail} = Enum.split(initial, demand)
      {:noreply, head, tail}
    end

    def handle_cast({:add, items}, state), do: {:noreply, [], state ++ items}
  end

  defmodule Consumer do
    @moduledoc false
    use GenStage

    def init(_) do
      {:consumer, %{}}
    end

    def handle_subscribe(:producer, opts, from, producers) do
      # We will only allow max_demand events every 5000 milliseconds
      pending = opts[:max_demand] || 1000
      interval = opts[:interval] || 5000

      # Register the producer in the state
      producers = Map.put(producers, from, {pending, interval})
      # Ask for the pending events and schedule the next time around
      producers = ask_and_schedule(producers, from)

      # Returns manual as we want control over the demand
      {:manual, producers}
    end

    def handle_cancel(_, from, producers) do
      # Remove the producers from the map on unsubscribe
      {:noreply, [], Map.delete(producers, from)}
    end

    def handle_events(events, from, producers) do
      # Bump the amount of pending events for the given producer
      producers =
        Map.update!(producers, from, fn {pending, interval} ->
          {pending + length(events), interval}
        end)

      # Consume the events by printing them.
      IO.inspect(events)

      # A producer_consumer would return the processed events here.
      {:noreply, [], producers}
    end

    def handle_info({:ask, from}, producers) do
      # This callback is invoked by the Process.send_after/3 message below.
      {:noreply, [], ask_and_schedule(producers, from)}
    end

    defp ask_and_schedule(producers, from) do
      case producers do
        %{^from => {pending, interval}} ->
          GenStage.ask(from, pending)
          Process.send_after(self(), {:ask, from}, interval)
          Map.put(producers, from, {0, interval})

        %{} ->
          producers
      end
    end
  end
end

{:ok, producer} = GenStage.start_link(Siblings.Throttler.Producer, Enum.to_list(1..100))
{:ok, consumer} = GenStage.start_link(Siblings.Throttler.Consumer, :ok)

GenServer.cast(producer, {:add, Enum.to_list(101..200)})

# Ask for 10 items every 2 seconds.
GenStage.sync_subscribe(consumer, to: producer, max_demand: 10, interval: 2000)
Process.sleep(:infinity)
