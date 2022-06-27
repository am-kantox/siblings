defmodule Siblings.Test.FSM do
  @moduledoc false

  @fsm """
  s1 --> |to_s2| s2
  s1 --> |to_s3| s3
  """

  use Finitomata, @fsm

  def on_transition(:s1, :to_s2, nil, %{pid: pid} = payload) do
    send(pid, :s1_s2)
    {:ok, :s2, payload}
  end

  def on_transition(:s2, :__end__, nil, %{pid: pid} = payload) do
    send(pid, :s2_end)
    {:ok, :*, payload}
  end
end
