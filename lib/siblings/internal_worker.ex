defmodule Siblings.InternalWorker do
  @moduledoc """
  The internal process to manage `Siblings.Worker` subsequent runs
  along with its _FSM_.
  """

  require Logger

  alias Siblings.Telemetria, as: T
  alias Siblings.Worker, as: W

  use GenServer
  use Boundary, deps: [Siblings.Lookup, Siblings.Telemetria], exports: [State]
  if T.enabled?(), do: use(Telemetria)

  defmodule State do
    @moduledoc """
    The state of the worker.
    """
    @type t :: %{
            __struct__: __MODULE__,
            id: W.id(),
            initial_payload: W.payload(),
            worker: module(),
            fsm: nil | {reference(), pid()},
            lookup: nil | pid() | GenServer.name(),
            throttler: %{optional({module(), atom()}) => GenServer.name()},
            internal_state: nil | pid() | GenServer.name(),
            hibernate?: boolean(),
            offload: nil | (t() -> :ok),
            interval: nil | non_neg_integer(),
            schedule: nil | reference()
          }

    defstruct ~w|id initial_payload worker fsm lookup throttler internal_state hibernate? offload interval schedule|a

    defimpl Inspect do
      @moduledoc false
      import Inspect.Algebra

      def inspect(%State{fsm: nil} = state, opts) do
        concat(["#Sibling<", to_doc([id: state.id, initialized: false], opts), ">"])
      end

      def inspect(%State{fsm: {_, fsm_pid}} = state, opts) do
        doc = [
          id: state.id,
          fsm: if(Process.alive?(fsm_pid), do: GenServer.call(fsm_pid, :state)),
          worker: Function.capture(state.worker, :perform, 3),
          options: [
            internal_state: not is_nil(state.internal_state),
            lookup: not is_nil(state.lookup),
            throttler: map_size(state.throttler) > 0,
            hibernate?: state.hibernate?,
            offload: not is_nil(state.offload),
            interval: state.interval
          ]
        ]

        concat(["#Sibling<", to_doc(doc, opts), ">"])
      end
    end
  end

  @typedoc "Allowed options in a call to `start_link/4`"
  @type options :: [
          {:interval, nil | non_neg_integer()}
          | {:lookup, nil | pid() | GenServer.name()}
          | {:throttler, %{optional({module(), atom()}) => GenServer.name()}}
          | {:internal_state, nil | pid() | GenServer.name()}
          | {:name, GenServer.name()}
          | {:hibernate?, boolean()}
          | {:offload, (State.t() -> :ok)}
        ]

  @doc false
  @spec start_link(module(), W.id(), W.payload(), opts :: options()) :: GenServer.on_start()
  def start_link(worker, id, payload, opts \\ []) do
    {lookup, opts} = Keyword.pop(opts, :lookup)
    {throttler, opts} = Keyword.pop(opts, :throttler, %{})
    {internal_state, opts} = Keyword.pop(opts, :internal_state)
    {offload, opts} = Keyword.pop(opts, :offload)
    {hibernate?, opts} = Keyword.pop(opts, :hibernate?, false)
    {interval, opts} = Keyword.pop(opts, :interval)
    interval = if is_integer(interval) and interval >= 0, do: interval

    GenServer.start_link(
      __MODULE__,
      %State{
        id: id,
        initial_payload: payload,
        worker: worker,
        lookup: lookup,
        throttler: throttler,
        internal_state: internal_state,
        offload: offload,
        hibernate?: hibernate?,
        interval: interval
      },
      opts
    )
  end

  ## interface

  @doc false
  @spec state(pid | GenServer.name()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

  @doc false
  @spec call(pid | GenServer.name(), W.message()) ::
          W.call_result() | {:error, :callback_not_implemented}
  def call(server, message), do: GenServer.call(server, {:message, message})

  @doc false
  @spec reset(pid | GenServer.name(), non_neg_integer()) :: :ok
  def reset(server, interval), do: GenServer.cast(server, {:reset, interval})

  @doc false
  @spec transition(
          pid | GenServer.name(),
          Finitomata.Transition.event(),
          Finitomata.event_payload()
        ) :: :ok
  def transition(server, event, payload \\ nil),
    do: GenServer.cast(server, {:transition, event, payload})

  ## implementation

  @doc false
  @impl GenServer
  def init(%State{} = state) do
    state = start_fsm(state)

    state =
      if is_nil(state.interval),
        do: state,
        else: %State{state | schedule: schedule_work(state.interval)}

    {:ok, state}
  end

  @doc false
  @impl GenServer
  def handle_call(:state, _, %State{hibernate?: true} = state),
    do: {:reply, state, state, :hibernate}

  def handle_call(:state, _, state), do: {:reply, state, state}

  @doc false
  @impl GenServer
  def handle_call({:message, message}, _, state) do
    {result, state} =
      if function_exported?(state.worker, :on_call, 2),
        do: state.worker.on_call(message, state),
        else: {{:error, :callback_not_implemented}, state}

    if state.hibernate?, do: {:reply, result, state, :hibernate}, else: {:reply, result, state}
  end

  @doc false
  @impl GenServer
  def handle_cast({:reset, interval}, state) when is_integer(interval) and interval > 0 do
    if is_reference(state.schedule), do: Process.cancel_timer(state.schedule)
    {:noreply, %State{state | interval: interval, schedule: schedule_work(interval)}}
  end

  @doc false
  @impl GenServer
  def handle_cast({:reset, 0}, state) do
    schedule_work(0)
    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_cast({:transition, event, payload}, %State{fsm: {_ref, pid}} = state) do
    GenServer.cast(pid, {event, payload})
    if state.hibernate?, do: {:noreply, state, :hibernate}, else: {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info(:work, %State{fsm: {_ref, pid}} = state) do
    if is_reference(state.schedule), do: Process.cancel_timer(state.schedule)

    interval =
      case safe_perform(state) do
        :noop ->
          state.interval

        {:transition, event, payload} ->
          GenServer.cast(pid, {event, payload})
          state.interval

        {:reschedule, interval} ->
          interval

        {:error, error} ->
          Logger.warning("Worker.perform/2 raised (#{error})")
          state.interval
      end

    state = %State{state | schedule: schedule_work(interval)}
    if state.hibernate?, do: {:noreply, state, :hibernate}, else: {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, :normal}, %State{fsm: {ref, pid}} = state) do
    Process.demonitor(ref)

    if state.internal_state do
      down_info = %{
        worker: __MODULE__,
        id: state.id,
        payload: state.initial_payload,
        options: [
          lookup: state.lookup,
          internal_state: state.internal_state,
          offload: state.offload,
          hibernate?: state.hibernate?,
          interval: state.interval
        ]
      }

      GenServer.cast(state.internal_state, {:down, down_info})
    end

    {:stop, :normal, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{fsm: {ref, pid}} = state) do
    Logger.warning(
      "FSM has crashed (reason: #{inspect(reason)}), IMPLEMENT CALLBACK `on_init` TO REINIT"
    )

    {:noreply, start_fsm(state)}
  end

  @doc false
  @impl GenServer
  def terminate(:normal, state),
    do: update_lookup(state.lookup, state.id)

  @impl GenServer
  def terminate(_, state),
    do: if(is_function(state.offload, 1), do: state.offload.(state))

  @doc false
  @spec schedule_work(interval :: non_neg_integer()) :: :error | reference()
  defp schedule_work(0), do: Process.send(self(), :work, [])

  defp schedule_work(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :work, interval)

  defp schedule_work(_interval), do: :error

  @doc false
  # @spec start_fsm(State.t()) :: State.t()
  defp start_fsm(%State{worker: worker, fsm: nil} = state) do
    Code.ensure_loaded!(worker)

    finitomata =
      if function_exported?(worker, :finitomata, 0), do: worker.finitomata(), else: worker

    {:ok, fsm} = finitomata.start_link(state.initial_payload)
    start_fsm(%State{state | fsm: {Process.monitor(fsm), fsm}})
  end

  defp start_fsm(%State{fsm: {_ref, pid}} = state) do
    if function_exported?(state.worker, :on_init, 1), do: state.worker.on_init(pid)
    state
  end

  @doc false
  @spec update_lookup(nil | GenServer.name(), W.id()) :: :ok
  defp update_lookup(nil, _id), do: :ok
  defp update_lookup(lookup, id), do: Siblings.Lookup.del(lookup, id)

  @doc false
  if T.enabled?(), do: @telemetria(level: :info)

  defp safe_perform(%State{fsm: {_ref, pid}} = state) do
    %Finitomata.State{current: current, payload: payload} = GenServer.call(pid, :state)
    throttler = Map.get(state.throttler, {state.worker, current})
    maybe_throttled_perform(state.worker, current, state.id, payload, throttler)
  rescue
    err -> Exception.message(err)
  end

  defp maybe_throttled_perform(module, state, id, payload, nil) do
    module.perform(state, id, payload)
  end

  defp maybe_throttled_perform(module, state, id, payload, throttler) do
    Siblings.Throttler.call(throttler, fn -> module.perform(state, id, payload) end).result
  end
end
