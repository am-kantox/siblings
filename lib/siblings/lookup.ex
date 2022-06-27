defmodule Siblings.Lookup do
  @moduledoc false

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  def get(id, default \\ nil) do
    Agent.get(__MODULE__, &Map.get(&1, id, default))
  end

  def put(id, value) do
    Agent.update(__MODULE__, &Map.put(&1, id, value))
  end
end
