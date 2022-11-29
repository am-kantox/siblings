defmodule Siblings.Throttler.Consumer do
  @moduledoc false
  use GenStage

  alias Siblings.Throttler

  @throttler_options Application.compile_env(:siblings, :throttler, [])
  @max_demand Keyword.get(@throttler_options, :max_demand, 10)
  @interval Keyword.get(@throttler_options, :interval, 1000)

  def start_link(initial \\ :ok),
    do: GenStage.start_link(__MODULE__, initial)

  @impl GenStage
  def init(opts) do
    max_demand = Keyword.get(opts, :max_demand, @max_demand)
    interval = Keyword.get(opts, :interval, @interval)

    {:consumer, %{__throttler_options__: %{max_demand: max_demand, interval: interval}}}
  end

  @impl GenStage
  def handle_subscribe(:producer, opts, from, producers) do
    max_demand =
      Keyword.get_lazy(opts, :max_demand, fn ->
        get_in(producers, ~w|__throttler_options__ max_demand|a)
      end)

    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        get_in(producers, ~w|__throttler_options__ interval|a)
      end)

    producers =
      producers
      |> Map.put(from, {max_demand, interval})
      |> ask_and_schedule(from)

    # `manual` to control over the demand
    {:manual, producers}
  end

  @impl GenStage
  def handle_cancel(_, from, producers),
    do: {:noreply, [], Map.delete(producers, from)}

  @impl GenStage
  def handle_events(events, from, producers) do
    producers =
      Map.update!(producers, from, fn {pending, interval} ->
        {pending + length(events), interval}
      end)

    perform(events)

    {:noreply, [], producers}
  end

  @impl GenStage
  def handle_info({:ask, from}, producers),
    do: {:noreply, [], ask_and_schedule(producers, from)}

  defp ask_and_schedule(
         %{__throttler_options__: %{max_demand: max_demand, interval: interval}} = producers,
         from
       ) do
    case producers do
      %{^from => {0, _interval}} ->
        GenStage.ask(from, max_demand)
        Process.send_after(self(), {:ask, from}, interval)
        producers

      %{^from => {pending, interval}} ->
        GenStage.ask(from, pending)
        Process.send_after(self(), {:ask, from}, interval)
        Map.put(producers, from, {0, interval})

      %{} ->
        producers
    end
  end

  @spec perform([Throttler.t()]) :: :ok
  defp perform(events) do
    Enum.each(events, fn %Throttler{from: from, fun: fun, args: args} = throttler ->
      result = fun.(args)

      case from do
        {pid, _alias_ref} when is_pid(pid) ->
          GenStage.reply(from, %Throttler{throttler | result: result})

        nil ->
          Throttler.debug(%Throttler{throttler | result: result}, label: "Malformed owner")
      end
    end)
  end
end
