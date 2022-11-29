defmodule Siblings.Throttler do
  @moduledoc """
  The internal definition of the call to throttle. The result will be send to
  `from` as `{:throttler, result}`.
  """

  @type t :: %{
          __struct__: Siblings.Throttler,
          from: pid(),
          fun: (keyword() -> any()),
          args: keyword(),
          result: any(),
          payload: any()
        }

  @type throttlee :: t() | {(keyword() -> any()), [any()]}

  defstruct ~w|from fun args result payload|a

  defmodule Producer do
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
          %Throttler{from: from, fun: &IO.inspect/1, args: [value: value]}
      end)
    end
  end

  defmodule Consumer do
    @moduledoc false
    use GenStage

    @throttler_options Application.compile_env(:siblings, :throttler, [])
    @max_demand Keyword.get(@throttler_options, :max_demand, 10)
    @interval Keyword.get(@throttler_options, :interval, 5000)

    def start_link(initial \\ :ok),
      do: GenStage.start_link(__MODULE__, initial)

    @impl GenStage
    def init(opts) do
      max_demand = Keyword.get(opts, :max_demand, @max_demand)
      interval = Keyword.get(opts, :interval, @interval)

      {:consumer, %{__throttler_options__: [max_demand: max_demand, interval: interval]}}
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

      producers = producers |> Map.put(from, {max_demand, interval}) |> ask_and_schedule(from)

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

    @spec perform([Throttler.t()]) :: :ok
    defp perform(events) do
      Enum.each(events, fn %{from: from, fun: fun, args: args} = throttler ->
        result = fun.(args)

        case from do
          pid when is_pid(pid) ->
            GenStage.reply(from, %{throttler | result: result})

          {pid, _alias_ref} when is_pid(pid) ->
            GenStage.reply(from, %{throttler | result: result})

          nil ->
            IO.inspect(%{throttler | result: result})
        end
      end)
    end
  end

  use Supervisor

  alias Siblings.Throttler.{Consumer, Producer}

  def start_link(opts) do
    name = Keyword.get(opts, :name, Siblings.default_fqn())
    opts = Keyword.put_new(opts, :name, name)
    Supervisor.start_link(__MODULE__, opts, name: Siblings.throttler_fqn(name))
  end

  @impl Supervisor
  def init(opts) do
    {initial, opts} = Keyword.pop(opts, :initial, [])
    {name, opts} = Keyword.pop!(opts, :name)

    children = [
      {Producer, initial},
      {Consumer, opts}
    ]

    flags = Supervisor.init(children, strategy: :one_for_one)

    Task.start_link(fn ->
      opts =
        opts
        |> Keyword.take(~w|max_demand interval|)
        |> Keyword.put(:to, producer(name))

      GenStage.sync_subscribe(consumer(name), opts)
    end)

    flags
  end

  def producer(name \\ Siblings.default_fqn()), do: lookup(Producer, name)
  def consumer(name \\ Siblings.default_fqn()), do: lookup(Consumer, name)

  defp lookup(who, name) do
    name
    |> Siblings.throttler_fqn()
    |> Supervisor.which_children()
    |> Enum.find(&match?({_name, _pid, :worker, [^who]}, &1))
    |> case do
      {_, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end
  end
end

Siblings.Throttler.start_link(initial: Enum.to_list(1..100))
GenStage.call(Siblings.Throttler.producer(), {:add, Enum.to_list(101..200)}, :infinity)
Process.sleep(:infinity)
