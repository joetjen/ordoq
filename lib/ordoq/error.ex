defmodule Ordoq.Error do
  @moduledoc """
  Defines the stable, typed failures returned by Ordoq.

  Every failure carries a machine-readable `:code`, a fixed human-readable
  `:message`, and free-form `:details` describing the specific occurrence. The
  code is the stable part: match on it rather than on message text.

  Each code has a constructor of the same name:

      iex> error = Ordoq.Error.overloaded(%{limit: 100})
      iex> {error.code, error.details}
      {:overloaded, %{limit: 100}}
  """

  @typedoc "An error owned by Ordoq."
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: term()}

  defexception [:code, :message, details: %{}]

  @messages [
    await_idle_failed: "One or more accepted jobs failed",
    await_idle_timeout: "Queue did not become idle before its deadline",
    cancelled: "Job was cancelled",
    dependency_unavailable: "A configured optional dependency is unavailable",
    drain_timeout: "Queue drain deadline expired",
    duplicate_name: "A job with this name already exists",
    execution_failed: "Job execution failed",
    invalid_config: "Ordoq configuration is invalid",
    invalid_job: "Job definition is invalid",
    job_not_found: "Job was not found",
    overloaded: "Queue capacity has been reached",
    shutting_down: "Queue is shutting down",
    timeout: "Job execution timed out"
  ]

  for {code, message} <- @messages do
    @doc "Builds the `#{inspect(code)}` error: #{message}."
    @spec unquote(code)(term()) :: t()
    def unquote(code)(details \\ %{}),
      do: %__MODULE__{code: unquote(code), message: unquote(message), details: details}
  end

  @doc "Returns every code this module defines, for exhaustiveness checks."
  @spec codes() :: [atom()]
  def codes, do: unquote(Keyword.keys(@messages))

  @impl true
  @spec exception(keyword()) :: t()
  def exception(options) when is_list(options) do
    %__MODULE__{
      code: Keyword.get(options, :code, :execution_failed),
      message: Keyword.get(options, :message, "Job execution failed"),
      details: Keyword.get(options, :details, %{})
    }
  end

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message
end
