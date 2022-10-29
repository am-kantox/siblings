defmodule Siblings.Killer do
  @moduledoc false

  use GenServer

  @spec start_link([{:name, GenServer.name()}, {:pid, pid() | GenServer.name()}]) ::
          GenServer.on_start()
  def start_link(name: name, pid: pid, callback: callback) when is_atom(name) do
    GenServer.start_link(__MODULE__, %{name: name, pid: pid, callback: callback},
      name: Siblings.killer_fqn(name)
    )
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast({:down, _down_info}, state) do
    with ref when is_reference(ref) <- Map.get(state, :timer), do: Process.cancel_timer(ref)
    schedule_work()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:work, %{name: name, pid: pid, callback: callback} = state) do
    if Siblings.children(:pids, name) == [] do
      if is_function(callback, 0), do: callback.()
      Supervisor.stop(pid)

      {:stop, :normal, state}
    else
      {:noreply, Map.put(state, :timer, schedule_work())}
    end
  end

  @spec schedule_work() :: reference()
  defp schedule_work,
    do: Process.send_after(self(), :work, 5_000)
end
