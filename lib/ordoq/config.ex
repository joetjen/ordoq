defmodule Ordoq.Config do
  @moduledoc "Loads and validates Ordoq's bounded runtime settings."

  alias Ordoq.Error

  @mix_env Mix.env()
  @development_build @mix_env == :dev
  @docs_build @mix_env == :docs
  @production_build @mix_env == :prod
  @test_build @mix_env == :test
  @allowed_keys [
    :admission_timeout_ms,
    :default_priority,
    :default_retry_base_ms,
    :default_ttr_ms,
    :health_gate,
    :max_attempts,
    :max_delay_ms,
    :max_in_flight,
    :max_priority,
    :max_queued,
    :max_retry_delay_ms,
    :max_ttr_ms,
    :min_priority,
    :retry_jitter_ms,
    :shutdown_timeout_ms
  ]
  @defaults [
    admission_timeout_ms: :timer.seconds(5),
    default_priority: 10,
    default_retry_base_ms: 250,
    default_ttr_ms: :timer.seconds(60),
    health_gate: nil,
    max_attempts: 5,
    max_delay_ms: :timer.hours(24 * 7),
    max_in_flight: 4,
    max_priority: 1_000,
    max_queued: 1_024,
    max_retry_delay_ms: :timer.seconds(30),
    max_ttr_ms: :timer.hours(1),
    min_priority: 0,
    retry_jitter_ms: 250,
    shutdown_timeout_ms: :timer.seconds(5)
  ]

  @enforce_keys @allowed_keys
  defstruct @allowed_keys

  @typedoc "Validated immutable Ordoq runtime configuration."
  @opaque t :: %__MODULE__{}

  ##
  ## Public API
  ##

  # Public functions

  @doc "Loads and validates the optional `Ordoq.Config` application namespace."

  @spec load() :: {:ok, t()} | {:error, Error.t()}
  def load do
    :ordoq
    |> Application.get_env(__MODULE__, [])
    |> new()
  end

  @doc "Validates an explicit Ordoq configuration keyword list."
  @spec new(keyword() | term()) :: {:ok, t()} | {:error, Error.t()}
  def new(settings) when is_list(settings) do
    with :ok <- validate_keys(settings),
         values <- Keyword.merge(@defaults, settings),
         :ok <- validate_values(values),
         :ok <- validate_relationships(values) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  def new(_settings), do: invalid(:settings, :supported_unique_keyword_list)

  @doc "Returns the admission call timeout in milliseconds."
  @spec admission_timeout_ms(t()) :: pos_integer()
  def admission_timeout_ms(%__MODULE__{admission_timeout_ms: value}), do: value

  @doc "Returns the default numerical priority; lower values execute first."
  @spec default_priority(t()) :: non_neg_integer()
  def default_priority(%__MODULE__{default_priority: value}), do: value

  @doc "Returns the default initial retry delay in milliseconds."
  @spec default_retry_base_ms(t()) :: non_neg_integer()
  def default_retry_base_ms(%__MODULE__{default_retry_base_ms: value}), do: value

  @doc "Returns the default time-to-run in milliseconds."
  @spec default_ttr_ms(t()) :: pos_integer()
  def default_ttr_ms(%__MODULE__{default_ttr_ms: value}), do: value

  @doc "Returns the optional health gate controlling job admission and dispatch."
  @spec health_gate(t()) :: atom() | nil
  def health_gate(%__MODULE__{health_gate: value}), do: value

  @doc "Returns the maximum attempts accepted for one job."
  @spec max_attempts(t()) :: pos_integer()
  def max_attempts(%__MODULE__{max_attempts: value}), do: value

  @doc "Returns the maximum delayed-enqueue duration in milliseconds."
  @spec max_delay_ms(t()) :: non_neg_integer()
  def max_delay_ms(%__MODULE__{max_delay_ms: value}), do: value

  @doc "Returns the maximum number of concurrently executing jobs."
  @spec max_in_flight(t()) :: pos_integer()
  def max_in_flight(%__MODULE__{max_in_flight: value}), do: value

  @doc "Returns the inclusive maximum job priority."
  @spec max_priority(t()) :: non_neg_integer()
  def max_priority(%__MODULE__{max_priority: value}), do: value

  @doc "Returns the maximum number of admitted jobs not currently running."
  @spec max_queued(t()) :: pos_integer()
  def max_queued(%__MODULE__{max_queued: value}), do: value

  @doc "Returns the maximum retry delay in milliseconds."
  @spec max_retry_delay_ms(t()) :: non_neg_integer()
  def max_retry_delay_ms(%__MODULE__{max_retry_delay_ms: value}), do: value

  @doc "Returns the maximum time-to-run in milliseconds."
  @spec max_ttr_ms(t()) :: pos_integer()
  def max_ttr_ms(%__MODULE__{max_ttr_ms: value}), do: value

  @doc "Returns the inclusive minimum job priority."
  @spec min_priority(t()) :: non_neg_integer()
  def min_priority(%__MODULE__{min_priority: value}), do: value

  @doc "Returns the maximum deterministic retry jitter in milliseconds."
  @spec retry_jitter_ms(t()) :: non_neg_integer()
  def retry_jitter_ms(%__MODULE__{retry_jitter_ms: value}), do: value

  @doc "Returns the supervisor's bounded shutdown timeout in milliseconds."
  @spec shutdown_timeout_ms(t()) :: pos_integer()
  def shutdown_timeout_ms(%__MODULE__{shutdown_timeout_ms: value}), do: value

  @doc "Returns whether this library was compiled for development."
  @spec development?() :: boolean()
  def development?, do: @development_build

  @doc "Returns whether this library was compiled for documentation."
  @spec docs?() :: boolean()
  def docs?, do: @docs_build

  @doc "Returns the Mix build environment captured at compilation."
  @spec mix_env() :: atom()
  def mix_env, do: @mix_env

  @doc "Returns whether this library was compiled for production."
  @spec production?() :: boolean()
  def production?, do: @production_build

  @doc "Returns whether this library was compiled for tests."
  @spec test?() :: boolean()
  def test?, do: @test_build

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Rejects unknown, duplicate, and non-keyword settings.
  @spec validate_keys(term()) :: :ok | {:error, Error.t()}
  defp validate_keys(settings) do
    keys = if Keyword.keyword?(settings), do: Keyword.keys(settings), else: []

    if Keyword.keyword?(settings) and Enum.uniq(keys) == keys and keys -- @allowed_keys == [],
      do: :ok,
      else: invalid(:settings, :supported_unique_keyword_list)
  end

  # Validates each setting's independent numerical contract.
  @spec validate_values(keyword()) :: :ok | {:error, Error.t()}
  defp validate_values(values) do
    positive = [
      :admission_timeout_ms,
      :default_ttr_ms,
      :max_attempts,
      :max_in_flight,
      :max_queued,
      :max_ttr_ms,
      :shutdown_timeout_ms
    ]

    non_negative = @allowed_keys -- (positive ++ [:health_gate])

    cond do
      Enum.any?(positive, &(not positive_integer?(values[&1]))) ->
        invalid(:settings, :positive_integer_limits)

      Enum.any?(non_negative, &(not non_negative_integer?(values[&1]))) ->
        invalid(:settings, :non_negative_integer_limits)

      not valid_gate?(values[:health_gate]) ->
        invalid(:health_gate, :atom_or_nil)

      true ->
        :ok
    end
  end

  # Ensures defaults and lower bounds remain inside their configured maxima.
  @spec validate_relationships(keyword()) :: :ok | {:error, Error.t()}
  defp validate_relationships(values) do
    valid? =
      values[:min_priority] <= values[:default_priority] and
        values[:default_priority] <= values[:max_priority] and
        values[:default_ttr_ms] <= values[:max_ttr_ms] and
        values[:default_retry_base_ms] <= values[:max_retry_delay_ms] and
        values[:retry_jitter_ms] <= values[:max_retry_delay_ms]

    if valid?, do: :ok, else: invalid(:settings, :consistent_bounds)
  end

  # Checks a strictly positive integer setting.
  @spec positive_integer?(term()) :: boolean()
  defp positive_integer?(value), do: is_integer(value) and value > 0

  # Checks a non-negative integer setting.
  @spec non_negative_integer?(term()) :: boolean()
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  # Accepts no health integration or one statically named admission gate.
  @spec valid_gate?(term()) :: boolean()
  defp valid_gate?(nil), do: true
  defp valid_gate?(gate), do: is_atom(gate) and gate not in [nil, true, false]

  # Builds a bounded configuration error without echoing supplied settings.
  @spec invalid(atom(), atom()) :: {:error, Error.t()}
  defp invalid(field, expected), do: {:error, Error.invalid_config(%{field: field, expected: expected})}
end
