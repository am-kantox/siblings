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
  def handle_cast({:down, down_info}, %{name: name, pid: pid, callback: callback}) do
    Task.start(fn ->
      if Siblings.children(:pids, name) == [] do
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if is_function(callback, 1), do: callback.(down_info)
        Supervisor.stop(pid)
      end
    end)

    {:stop, :normal, %{pid: pid, down_info: down_info}}
  end
end
