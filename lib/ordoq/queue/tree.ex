defmodule Ordoq.Queue.Tree do
  @moduledoc false

  # A minimal typed wrapper over Erlang's `:gb_trees`, covering exactly what the
  # queue needs. `:gb_trees` raises on an empty tree, so `smallest/1` reports
  # emptiness as a value instead -- the queue asks "what is next?" constantly and
  # an empty queue is ordinary, not exceptional.

  @typedoc "An ordered tree of queue keys to job identifiers."
  @opaque t :: :gb_trees.tree()

  @doc "Returns an empty tree."
  @spec new() :: t()
  def new, do: :gb_trees.empty()

  @doc "Inserts or replaces `key`."
  @spec put(t(), term(), term()) :: t()
  def put(tree, key, value), do: :gb_trees.enter(key, value, tree)

  @doc "Removes `key`, tolerating its absence."
  @spec delete(t(), term()) :: t()
  def delete(tree, key), do: :gb_trees.delete_any(key, tree)

  @doc "Returns how many entries the tree holds."
  @spec size(t()) :: non_neg_integer()
  def size(tree), do: :gb_trees.size(tree)

  @doc "Returns the lowest-ordered entry, or `:empty`."
  @spec smallest(t()) :: {:ok, {term(), term()}} | :empty
  def smallest(tree) do
    if :gb_trees.is_empty(tree), do: :empty, else: {:ok, :gb_trees.smallest(tree)}
  end
end
