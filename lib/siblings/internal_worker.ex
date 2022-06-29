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
            id: W.id(),
            initial_payload: W.payload(),
            worker: module(),
            fsm: {reference(), pid()},
            lookup: nil | GenServer.name(),
            offload: nil | (t() -> :ok),
            interval: non_neg_integer()
          }
    defstruct ~w|id initial_payload worker fsm lookup offload interval|a

    defimpl Inspect do
      @moduledoc false
      import Inspect.Algebra

      def inspect(%State{fsm: nil} = state, opts) do
        concat(["#Sibling<", to_doc([id: state.id, initialized: false], opts), ">"])
      end

      def inspect(%State{fsm: {_, fsm_pid}} = state, opts) do
        doc = [
          id: state.id,
          fsm: GenServer.call(fsm_pid, :state),
          worker: Function.capture(state.worker, :perform, 3),
          interval: state.interval
        ]

        concat(["#Sibling<", to_doc(doc, opts), ">"])
      end
    end
  end

  @typedoc "Allowed options in a call to `start_link/4`"
  @type options :: [
          {:interval, non_neg_integer()}
          | {:name, GenServer.name()}
          | {:offload, (State.t() -> :ok)}
        ]

  @doc false
  @spec start_link(module(), W.id(), W.payload(), opts :: options()) :: GenServer.on_start()
  def start_link(worker, id, payload, opts \\ []) do
    {interval, opts} = Keyword.pop(opts, :interval, 5_000)
    {lookup, opts} = Keyword.pop(opts, :lookup)
    {offload, opts} = Keyword.pop(opts, :offload)

    GenServer.start_link(
      __MODULE__,
      %State{
        id: id,
        initial_payload: payload,
        worker: worker,
        lookup: lookup,
        offload: offload,
        interval: interval
      },
      opts
    )
  end

  @doc false
  @impl GenServer
  def init(%State{} = state) do
    state = start_fsm(state)

    update_lookup(:put, state.lookup, state.id)
    schedule_work(state.interval)
    {:ok, state}
  end

  @doc false
  @spec state(pid | GenServer.name()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

  @doc false
  @impl GenServer
  def handle_call(:state, _, state), do: {:reply, state, state}

  @doc false
  @impl GenServer
  def handle_info(:work, %State{fsm: {_ref, pid}} = state) do
    case safe_perform(state) do
      :noop ->
        :ok

      {:transition, event, payload} ->
        GenServer.cast(pid, {event, payload})

      {:error, error} ->
        Logger.warn("Worker.perform/2 raised (#{inspect(error)})")
    end

    schedule_work(state.interval)
    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, :normal}, %State{fsm: {ref, pid}} = state) do
    Logger.info("FSM Shut Us Down")
    Process.demonitor(ref)
    {:stop, :normal, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{fsm: {ref, pid}} = state) do
    Logger.warn("FSM Down (reason: #{inspect(reason)}), IMPLEMENT CALLBACK TO REINIT")
    {:noreply, start_fsm(state)}
  end

  @doc false
  @impl GenServer
  def terminate(:normal, state),
    do: update_lookup(:del, state.lookup, state.id)

  @impl GenServer
  def terminate(_, state),
    do: if(is_function(state.offload, 1), do: state.offload.(state))

  @doc false
  @spec schedule_work(interval :: non_neg_integer()) :: reference()
  defp schedule_work(interval) when interval > 0, do: Process.send_after(self(), :work, interval)
  defp schedule_work(_interval), do: :ok

  @doc false
  # @spec start_fsm(State.t()) :: State.t()
  defp start_fsm(%State{worker: worker, fsm: nil} = state) do
    Code.ensure_loaded!(worker)

    fsm_impl = if function_exported?(worker, :fsm, 0), do: worker.fsm(), else: worker
    {:ok, fsm} = fsm_impl.start_link(state.initial_payload)
    start_fsm(%State{state | fsm: {Process.monitor(fsm), fsm}})
  end

  defp start_fsm(%State{fsm: {_ref, pid}} = state) do
    if function_exported?(state.worker, :reinit, 1), do: state.worker.reinit(pid)
    state
  end

  @doc false
  @spec update_lookup(:put | :del, nil | GenServer.name(), W.id()) :: :ok
  defp update_lookup(_action, nil, _id), do: :ok
  defp update_lookup(:put, lookup, id), do: Siblings.Lookup.put(lookup, id, self())
  defp update_lookup(:del, lookup, id), do: Siblings.Lookup.del(lookup, id)

  @doc false
  if T.enabled?(), do: @telemetria(level: :info)

  defp safe_perform(%State{fsm: {_ref, pid}} = state) do
    %Finitomata.State{current: current, payload: payload} = GenServer.call(pid, :state)
    state.worker.perform(current, state.id, payload)
  rescue
    err ->
      case err do
        %{__exception__: true} ->
          {:error, Exception.message(err)}
      end
  end
end
