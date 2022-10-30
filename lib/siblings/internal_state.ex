defmodule Siblings.InternalState do
  @moduledoc false

  use GenServer

  @spec start_link([{:name, GenServer.name()}, {:pid, pid() | GenServer.name()}]) ::
          GenServer.on_start()
  def start_link(opts) do
    state =
      opts
      |> Map.new()
      |> Map.put_new(:name, Siblings.default_fqn())
      |> Map.put_new(:payload, %{})
      |> Map.put_new(:timeout, 5_000)

    GenServer.start_link(__MODULE__, state, name: Siblings.internal_state_fqn(state.name))
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast({:down, down_info}, state) do
    with ref when is_reference(ref) <- Map.get(state, :timer), do: Process.cancel_timer(ref)
    schedule_work(state.timeout)
    {:noreply, Map.put(state, :last_child, down_info)}
  end

  @impl GenServer
  def handle_cast({:put, key, value}, state) do
    {:noreply, put_in(state, [:payload, key], value)}
  end

  @impl GenServer
  def handle_cast({:update, key, fun}, state) do
    {:noreply, update_in(state, [:payload, key], fun)}
  end

  @impl GenServer
  def handle_cast({:delete, key}, state) do
    {:noreply, update_in(state, [:payload], &Map.delete(&1, key))}
  end

  @impl GenServer
  def handle_info(:work, state) do
    if Siblings.children(:pids, state.name) == [] do
      case state.callback do
        cb when is_function(cb, 0) -> cb.()
        cb when is_function(cb, 1) -> cb.(state.payload)
        _ -> :ok
      end

      Supervisor.stop(state.pid)

      {:stop, :normal, state}
    else
      {:noreply, Map.put(state, :timer, schedule_work(state.timeout))}
    end
  end

  @spec schedule_work(non_neg_integer()) :: reference()
  defp schedule_work(timeout),
    do: Process.send_after(self(), :work, timeout)
end
