defmodule Ordoq.Telemetry.LoggerContext do
  @moduledoc """
  The default context propagation: carries `Logger.metadata/0` across processes.

  A job is enqueued in one process and executed in another, so metadata the
  caller had attached — request identifiers, a correlation id — would otherwise
  be absent from every log line the job produces. This copies it across, and
  restores whatever the executing process had afterwards.

  Replace it to propagate something else, such as a tracing span:

      config :ordoq, context: MyApp.TraceContext
  """

  @behaviour Ordoq.Telemetry.Context

  @impl true
  @spec capture() :: keyword()
  def capture, do: Logger.metadata()

  @impl true
  @spec with(term(), (-> result)) :: result when result: term()
  def with(metadata, function) when is_list(metadata) and is_function(function, 0) do
    previous = Logger.metadata()

    try do
      Logger.metadata(metadata)
      function.()
    after
      Logger.reset_metadata(previous)
    end
  end

  def with(_context, function) when is_function(function, 0), do: function.()
end
