defmodule Ordoq.Stats do
  @moduledoc "A bounded snapshot of local Ordoq capacity and utilization."

  @enforce_keys [:capacity, :delayed, :in_flight, :locked, :queued]
  defstruct @enforce_keys

  @typedoc "A queue snapshot containing counts only."
  @type t :: %__MODULE__{
          capacity: pos_integer(),
          delayed: non_neg_integer(),
          in_flight: non_neg_integer(),
          locked: non_neg_integer(),
          queued: non_neg_integer()
        }
end
