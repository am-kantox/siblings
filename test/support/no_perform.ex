defmodule Siblings.Test.NoPerform do
  @moduledoc false

  require Logger

  @behaviour Siblings.Worker

  @impl Siblings.Worker
  def perform(_, _, _), do: :noop

  @fsm """
  s1 --> |to_s2| s2
  s2 --> |in_s2| s2
  s2 --> |to_s3| s3
  """

  use Finitomata, @fsm

  def on_transition(:s1, :to_s2, nil, %{pid: pid} = payload) do
    send(pid, :s1_s2)
    {:ok, :s2, payload}
  end

  def on_transition(:s3, :__end__, nil, %{pid: pid} = payload) do
    send(pid, :s3_end)
    {:ok, :*, payload}
  end
end
