defmodule Siblings.Test.Worker do
  @moduledoc false

  require Logger

  @behaviour Siblings.Worker

  @impl Siblings.Worker
  def finitomata, do: Siblings.Test.FSM

  @impl Siblings.Worker
  def perform(:s1, id, payload) do
    Logger.info("PERFORM 1: " <> inspect({:s1, id, payload}))
    {:transition, :to_s2, nil}
  end

  def perform(:s2, id, payload) do
    Logger.info("PERFORM 2: " <> inspect({:s2, id, payload}))
    {:transition, :__end__, nil}
  end
end
