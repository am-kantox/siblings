defmodule Siblings.Test.Callable do
  @moduledoc false

  require Logger

  @behaviour Siblings.Worker

  @impl Siblings.Worker
  def perform(_, _, _), do: :noop

  @impl Siblings.Worker
  def on_call(message, state) when is_integer(message),
    do: {message * 2, state}

  @fsm """
  s1 --> |to_s2| s2
  s2 --> |to_s3| s3
  """

  use Finitomata, @fsm
end
