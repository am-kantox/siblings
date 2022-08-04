defmodule Siblings.Lookup do
  @moduledoc false

  use Agent

  use Boundary, deps: [Siblings]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, Siblings.default_fqn())

    fn -> %{} end
    |> Agent.start_link(name: lookup_fqn(name))
    |> tap(fn _ ->
      Task.start_link(fn ->
        :states
        |> Siblings.children(name)
        |> Enum.each(&put(lookup_fqn(name), &1.id, &1))
      end)
    end)
  end

  @spec get(module(), Siblings.Worker.id(), nil | pid()) :: nil | pid()
  def get(name \\ lookup_fqn(), id, default \\ nil),
    do: Agent.get(name, &Map.get(&1, id, default))

  @spec put(module(), Siblings.Worker.id(), nil | pid()) :: :ok
  def put(name \\ lookup_fqn(), id, value),
    do: Agent.update(name, &Map.put(&1, id, value))

  @spec del(module(), Siblings.Worker.id()) :: :ok
  def del(name \\ lookup_fqn(), id),
    do: Agent.update(name, &Map.delete(&1, id))

  @spec all(module()) :: %{optional(binary()) => pid()}
  def all(name \\ lookup_fqn()),
    do: Agent.get(name, & &1)

  @spec lookup_fqn(pid() | module()) :: module()
  def lookup_fqn(name_or_pid \\ Siblings.default_fqn())
  def lookup_fqn(pid) when is_pid(pid), do: pid
  def lookup_fqn(name), do: Module.concat(name, Lookup)
end
