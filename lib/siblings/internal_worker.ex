defmodule Siblings.InternalWorker do
  @moduledoc false

  use GenServer
  use Boundary, exports: [State]
  use Telemetria

  require Logger

  alias Siblings.Worker, as: W

  @typedoc "Allowed options in a call to `start_link/4`"
  @type options :: [{:interval, non_neg_integer()} | {:name, GenServer.name()}]

  defmodule State do
    @moduledoc false
    @type t :: %{
            worker: module(),
            fsm: {reference(), pid()},
            id: W.id(),
            initial_payload: W.payload(),
            interval: non_neg_integer()
          }
    defstruct ~w|worker fsm id initial_payload interval|a
  end

  @spec start_link(module(), W.id(), W.payload(), opts :: options()) :: GenServer.on_start()
  def start_link(worker, id, payload, opts \\ []) do
    {interval, opts} = Keyword.pop(opts, :interval, 5_000)

    GenServer.start_link(
      __MODULE__,
      %State{worker: worker, id: id, initial_payload: payload, interval: interval},
      opts
    )
  end

  @impl GenServer
  def init(%State{} = state) do
    state = start_fsm(state)
    schedule_work(state.interval)
    {:ok, state}
  end

  @spec state(GenServer.name()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

  @impl GenServer
  def handle_call(:state, _, state), do: {:reply, state, state}

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

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, :normal}, %State{fsm: {ref, pid}} = state) do
    Logger.info("FSM Shut Us Down")
    Process.demonitor(ref)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %State{fsm: {ref, pid}} = state) do
    Logger.warn("FSM Down (reason: #{inspect(reason)}), IMPLEMENT CALLBACK TO REINIT")
    {:noreply, start_fsm(state)}
  end

  @spec schedule_work(interval :: non_neg_integer()) :: reference()
  defp schedule_work(interval) when interval > 0, do: Process.send_after(self(), :work, interval)
  defp schedule_work(_interval), do: :ok

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

  # @spec safe_perform(State.t()) ::
  #         {:transition, Finitomata.Transition.event(), Finitomata.event_payload()}
  #         | :noop
  #         | {:error, String.t()}
  @telemetria level: :info
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
