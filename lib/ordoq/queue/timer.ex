defmodule Ordoq.Queue.Timer do
  @moduledoc false

  # Message scheduling, wrapped so a failure becomes an `Ordoq.Error` rather
  # than an Erlang tuple the queue would have to interpret at every call site.

  alias Ordoq.Error

  @typedoc "A reference to a scheduled message."
  @type timer_ref :: :timer.tref()

  @doc "Schedules `message` to `destination` after `duration_ms`."
  @spec send_after(non_neg_integer(), pid() | atom(), term()) ::
          {:ok, timer_ref()} | {:error, Error.t()}
  def send_after(duration_ms, destination, message) do
    case :timer.send_after(duration_ms, destination, message) do
      {:ok, timer_ref} -> {:ok, timer_ref}
      {:error, reason} -> {:error, Error.invalid_job(%{operation: :send_after, cause: reason})}
    end
  end

  @doc "Cancels a scheduled message, tolerating one that has already fired."
  @spec cancel(timer_ref()) :: :ok
  def cancel(timer_ref) do
    _ignored = :timer.cancel(timer_ref)
    :ok
  end
end
