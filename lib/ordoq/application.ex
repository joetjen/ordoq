defmodule Ordoq.Application do
  @moduledoc false

  use Application

  alias Ordoq.{Config, Queue}

  ##
  ## Callback Implementations
  ##

  # Behaviour callbacks

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid(), Config.t()} | {:error, term()}
  def start(_type, _arguments) do
    with {:ok, config} <- Config.load(),
         {:ok, supervisor} <- Supervisor.start_link(children(config), supervisor_options()) do
      {:ok, supervisor, config}
    end
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Defines bounded worker ownership before the queue that dispatches into it.
  @spec children(Config.t()) :: [Supervisor.child_spec()]
  defp children(config) do
    task_supervisor =
      Supervisor.child_spec(
        {Task.Supervisor, name: Ordoq.TaskSupervisor, max_children: Config.max_in_flight(config)},
        id: Ordoq.TaskSupervisor
      )

    queue =
      Supervisor.child_spec(
        {Queue, config},
        shutdown: Config.shutdown_timeout_ms(config)
      )

    [task_supervisor, queue]
  end

  # Returns the stable root-supervisor identity and restart strategy.
  @spec supervisor_options() :: keyword()
  defp supervisor_options, do: [strategy: :rest_for_one, name: Ordoq.Supervisor]
end
