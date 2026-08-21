defmodule Ordoq.Job do
  @moduledoc false

  alias Ordoq.Telemetry.Context
  alias Ordoq.{Config, Error}

  @allowed_options [:delay_ms, :max_attempts, :name, :priority, :retry_base_ms, :ttr_ms]
  @enforce_keys [
    :args,
    :attempt,
    :context,
    :function,
    :id,
    :max_attempts,
    :module,
    :name,
    :priority,
    :ready_at_ms,
    :retry_base_ms,
    :sequence,
    :status,
    :ttr_ms
  ]
  defstruct @enforce_keys ++ [:queue_key]

  @type status :: :delayed | :locked | :ready | :running
  @type name :: atom() | tuple() | nil
  @type schedulable :: %__MODULE__{status: :delayed | :ready}
  @type t :: %__MODULE__{
          args: list(),
          attempt: pos_integer(),
          context: Context.t(),
          function: atom(),
          id: pos_integer(),
          max_attempts: pos_integer(),
          module: module(),
          name: name(),
          priority: non_neg_integer(),
          queue_key: tuple() | nil,
          ready_at_ms: integer(),
          retry_base_ms: non_neg_integer(),
          sequence: pos_integer(),
          status: status(),
          ttr_ms: pos_integer()
        }

  ##
  ## Public API
  ##

  # Public functions

  @doc "Validates callback metadata and constructs an internal schedulable job."
  @spec new(pos_integer(), module(), atom(), list(), keyword(), Context.t(), Config.t(), integer()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(id, module, function, args, options, context, config, now_ms) do
    with :ok <- validate_options(options),
         :ok <- validate_mfa(module, function, args),
         {:ok, name} <- validate_name(Keyword.get(options, :name)),
         {:ok, priority} <- validate_priority(Keyword.get(options, :priority, Config.default_priority(config)), config),
         {:ok, ttr_ms} <- validate_ttr(Keyword.get(options, :ttr_ms, Config.default_ttr_ms(config)), config),
         {:ok, delay_ms} <- validate_delay(Keyword.get(options, :delay_ms, 0), config),
         {:ok, attempts} <- validate_attempts(Keyword.get(options, :max_attempts, 1), config),
         {:ok, retry_ms} <-
           validate_retry(Keyword.get(options, :retry_base_ms, Config.default_retry_base_ms(config)), config) do
      values = %{
        attempts: attempts,
        delay_ms: delay_ms,
        name: name,
        priority: priority,
        retry_ms: retry_ms,
        ttr_ms: ttr_ms
      }

      {:ok, build(id, {module, function, args}, values, context, now_ms)}
    end
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Constructs a validated job with the context captured by the submitting process.
  @spec build(pos_integer(), {module(), atom(), list()}, map(), Context.t(), integer()) :: t()
  defp build(id, {module, function, args}, values, context, now_ms) do
    %__MODULE__{
      args: args,
      attempt: 1,
      context: context,
      function: function,
      id: id,
      max_attempts: values.attempts,
      module: module,
      name: values.name,
      priority: values.priority,
      ready_at_ms: now_ms + values.delay_ms,
      retry_base_ms: values.retry_ms,
      sequence: id,
      status: if(values.delay_ms == 0, do: :ready, else: :delayed),
      ttr_ms: values.ttr_ms
    }
  end

  # Rejects duplicate or unsupported job options.
  @spec validate_options(term()) :: :ok | {:error, Error.t()}
  defp validate_options(options) do
    keys = if Keyword.keyword?(options), do: Keyword.keys(options), else: []

    if Keyword.keyword?(options) and Enum.uniq(keys) == keys and keys -- @allowed_options == [],
      do: :ok,
      else: invalid(:options, :supported_unique_keyword_list)
  end

  # Requires an exported callback that accepts the injected touch function.
  @spec validate_mfa(term(), term(), term()) :: :ok | {:error, Error.t()}
  defp validate_mfa(module, function, args)
       when is_atom(module) and is_atom(function) and is_list(args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args) + 1),
      do: :ok,
      else: invalid(:mfa, :exported_function_accepting_touch_and_arguments)
  end

  defp validate_mfa(_module, _function, _args), do: invalid(:mfa, :module_function_and_list)

  # Restricts names to bounded structural values that cannot conflict with numeric IDs.
  @spec validate_name(term()) :: {:ok, name()} | {:error, Error.t()}
  defp validate_name(nil), do: {:ok, nil}
  defp validate_name(name) when is_atom(name), do: {:ok, name}
  defp validate_name(name) when is_tuple(name) and tuple_size(name) <= 8, do: {:ok, name}
  defp validate_name(_name), do: invalid(:name, :atom_or_bounded_tuple)

  # Validates priority against the configured inclusive range.
  @spec validate_priority(term(), Config.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  defp validate_priority(priority, config) do
    if is_integer(priority) and priority >= Config.min_priority(config) and priority <= Config.max_priority(config),
      do: {:ok, priority},
      else: invalid(:priority, :configured_range)
  end

  # Validates one strictly positive time-to-run against its configured maximum.
  @spec validate_ttr(term(), Config.t()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp validate_ttr(ttr_ms, config) do
    if is_integer(ttr_ms) and ttr_ms > 0 and ttr_ms <= Config.max_ttr_ms(config),
      do: {:ok, ttr_ms},
      else: invalid(:ttr_ms, :configured_range)
  end

  # Validates an enqueue delay against its configured maximum.
  @spec validate_delay(term(), Config.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  defp validate_delay(delay_ms, config) do
    if is_integer(delay_ms) and delay_ms >= 0 and delay_ms <= Config.max_delay_ms(config),
      do: {:ok, delay_ms},
      else: invalid(:delay_ms, :configured_range)
  end

  # Validates the total number of permitted attempts.
  @spec validate_attempts(term(), Config.t()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp validate_attempts(attempts, config) do
    if is_integer(attempts) and attempts > 0 and attempts <= Config.max_attempts(config),
      do: {:ok, attempts},
      else: invalid(:max_attempts, :configured_range)
  end

  # Validates the initial retry delay against the configured cap.
  @spec validate_retry(term(), Config.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  defp validate_retry(retry_ms, config) do
    if is_integer(retry_ms) and retry_ms >= 0 and retry_ms <= Config.max_retry_delay_ms(config),
      do: {:ok, retry_ms},
      else: invalid(:retry_base_ms, :configured_range)
  end

  # Builds a bounded job-validation error without retaining submitted arguments.
  @spec invalid(atom(), atom()) :: {:error, Error.t()}
  defp invalid(field, expected), do: {:error, Error.invalid_job(%{field: field, expected: expected})}
end
