defmodule Siblings.Throttler do
  @moduledoc """
  The internal definition of the call to throttle. The result will be send to
  `from` as `{:throttler, result}`.
  """

  @type t :: %{
          __struct__: Siblings.Throttler,
          from: GenServer.from(),
          fun: (keyword() -> any()),
          args: keyword(),
          result: any(),
          payload: any()
        }

  @type throttlee :: t() | {(keyword() -> any()), [any()]}

  defstruct ~w|from fun args result payload|a

  use Supervisor

  require Logger

  alias Siblings.Throttler.{Consumer, Producer}

  def start_link(opts) do
    name = Keyword.get(opts, :name, Siblings.default_fqn())
    opts = Keyword.put_new(opts, :name, name)
    Supervisor.start_link(__MODULE__, opts, name: Siblings.throttler_fqn(name))
  end

  @impl Supervisor
  def init(opts) do
    {initial, opts} = Keyword.pop(opts, :initial, [])
    {name, opts} = Keyword.pop!(opts, :name)

    children = [
      {Producer, initial},
      {Consumer, opts}
    ]

    flags = Supervisor.init(children, strategy: :one_for_one)

    Task.start_link(fn ->
      opts =
        opts
        |> Keyword.take(~w|max_demand interval|a)
        |> Keyword.put_new(:to, producer(name))

      name
      |> consumer()
      |> GenStage.sync_subscribe(opts)
    end)

    flags
  end

  def add(name \\ Siblings.default_fqn(), requests) do
    GenStage.call(producer(name), {:add, requests}, :infinity)
  end

  @doc false
  def debug(anything, opts \\ []) do
    anything
    |> inspect(opts)
    |> Logger.debug()
  end

  @doc false
  def producer(name \\ Siblings.default_fqn()), do: lookup(Producer, name)
  @doc false
  def consumer(name \\ Siblings.default_fqn()), do: lookup(Consumer, name)

  defp lookup(who, name) do
    name
    |> Siblings.throttler_fqn()
    |> Supervisor.which_children()
    |> Enum.find(&match?({_name, _pid, :worker, [^who]}, &1))
    |> case do
      {_, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end
  end
end
