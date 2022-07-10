defmodule Siblings.Test.WorkerFSM do
  @moduledoc false

  require Logger

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

  @behaviour Siblings.Worker

  @impl Siblings.Worker
  def perform(:s1, id, payload) do
    Logger.info("PERFORM 1: " <> inspect({:s1, id, payload}))
    {:transition, :to_s2, nil}
  end

  @impl Siblings.Worker
  def perform(:s2, id, payload) do
    Logger.info("PERFORM 2: " <> inspect({:s2, id, payload}))
    :noop
  end

  @impl Siblings.Worker
  def perform(:s3, id, payload) do
    Logger.info("PERFORM 3: " <> inspect({:s3, id, payload}))
    {:transition, :__end__, nil}
  end
end
