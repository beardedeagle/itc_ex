defmodule ITC.Id do
  @moduledoc """
  Id trees: the share of the interval [0, 1) a stamp owns.

    * `0` owns nothing in this subinterval.
    * `1` owns all of it.
    * `{l, r}` splits it into a left and a right half.

  Every function here takes normalized trees and returns normalized trees.
  A normalized tree contains no `{0, 0}` or `{1, 1}` node anywhere. Results
  for anything else are undefined; check untrusted input with `normal?/1`.
  """

  @type t :: 0 | 1 | {t, t}

  @doc """
  Normalizes one node whose children are already normalized.

      iex> ITC.Id.norm({1, 1})
      1
      iex> ITC.Id.norm({1, 0})
      {1, 0}
  """
  @spec norm(t) :: t
  def norm({0, 0}), do: 0
  def norm({1, 1}), do: 1
  def norm(id), do: id

  @doc """
  Normalizes a well-formed id tree bottom-up.

      iex> ITC.Id.normalize({{1, 1}, {0, {0, 0}}})
      {1, 0}
  """
  @spec normalize(t) :: t
  def normalize({l, r}), do: norm({normalize(l), normalize(r)})
  def normalize(id) when id in [0, 1], do: id

  @doc """
  Splits an id into two disjoint ids whose union is the original.

      iex> ITC.Id.split(1)
      {{1, 0}, {0, 1}}
      iex> ITC.Id.split({1, 0})
      {{{1, 0}, 0}, {{0, 1}, 0}}
  """
  @spec split(t) :: {t, t}
  def split(0), do: {0, 0}
  def split(1), do: {{1, 0}, {0, 1}}

  def split({0, r}) do
    {r1, r2} = split(r)
    {{0, r1}, {0, r2}}
  end

  def split({l, 0}) do
    {l1, l2} = split(l)
    {{l1, 0}, {l2, 0}}
  end

  def split({l, r}), do: {{l, 0}, {0, r}}

  @doc """
  Sums two disjoint ids.

  The paper leaves `sum` undefined when the ids overlap. Overlap means two
  holders can record events in the same region, so their histories can no
  longer be told apart. This function reports it rather than silently
  returning the union.

      iex> {a, b} = ITC.Id.split(1)
      iex> ITC.Id.sum(a, b)
      {:ok, 1}
      iex> ITC.Id.sum(1, {1, 0})
      {:error, :overlapping_ids}
  """
  @spec sum(t, t) :: {:ok, t} | {:error, :overlapping_ids}
  def sum(a, b) do
    {:ok, do_sum(a, b)}
  catch
    :throw, :overlapping_ids -> {:error, :overlapping_ids}
  end

  defp do_sum(0, id), do: id
  defp do_sum(id, 0), do: id
  defp do_sum({l1, r1}, {l2, r2}), do: norm({do_sum(l1, l2), do_sum(r1, r2)})
  # Remaining cases pair `1` with a non-zero id: the two share some region.
  defp do_sum(_, _), do: throw(:overlapping_ids)

  @doc """
  Returns true when `term` is a well-formed, normalized id tree.

  Use this on anything that did not come from this module's own operations.

      iex> ITC.Id.normal?({1, 0})
      true
      iex> ITC.Id.normal?({1, 1})
      false
      iex> ITC.Id.normal?({2, 0})
      false
  """
  @spec normal?(term) :: boolean
  def normal?(0), do: true
  def normal?(1), do: true
  def normal?({0, 0}), do: false
  def normal?({1, 1}), do: false
  def normal?({l, r}), do: normal?(l) and normal?(r)
  def normal?(_), do: false

  @doc "Number of nodes in the tree."
  @spec node_count(t) :: pos_integer
  def node_count({l, r}), do: 1 + node_count(l) + node_count(r)
  def node_count(_leaf), do: 1
end
