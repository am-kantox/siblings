defmodule Siblings.Test.FSM do
  @moduledoc false

  @fsm """
  s1 --> |to_s2| s2
  s1 --> |to_s3| s3
  """

  use Finitomata, @fsm
end
