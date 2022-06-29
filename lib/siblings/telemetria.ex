defmodule Siblings.Telemetria do
  @moduledoc false

  use Boundary

  @spec enabled? :: boolean()
  def enabled?,
    do: match?({:module, Telemetria}, Code.ensure_compiled(Telemetria))
end
