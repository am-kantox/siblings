defmodule Siblings.Killer do
  @moduledoc false

  use GenServer

  @spec start_link([{:name, GenServer.name()}, {:pid, pid() | GenServer.name()}]) ::
          GenServer.on_start()
  def start_link(name: name, pid: pid) do
    GenServer.start_link(__MODULE__, pid, name: Siblings.killer_fqn(name))
  end

  @impl GenServer
  def init(pid), do: {:ok, %{pid: pid}}

  @impl GenServer
  def handle_cast({:down, down_info}, %{pid: pid}) do
    Task.start(fn -> Supervisor.stop(pid) end)
    {:stop, :normal, %{pid: pid, down_info: down_info}}
  end
end
