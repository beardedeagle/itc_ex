defmodule ITC.Event do
  @moduledoc """
  Event trees: the causal history a stamp has seen, as a function over [0, 1).

    * `n` is the constant `n` across the subinterval.
    * `{n, l, r}` adds `n` to the left half described by `l` and the right half
      described by `r`.

  A normalized tree has no `{n, m, m}` node with integer `m`, and in every
  `{n, l, r}` node at least one child has minimum `0`. Except for normalization
  and validation, functions here take normalized trees and return normalized
  trees. `min_of/1` relies on
  that invariant and reads the base of a node in constant time.
  """

  alias ITC.Id

  # Same set the reference implementation inlines (lift, drop, base, height).
  @compile {:inline, lift: 2, sink: 2, min_of: 1, max_of: 1}

  @type t :: non_neg_integer | {non_neg_integer, t, t}

  # The paper's "large constant" N. It makes `grow/2` prefer any path that
  # does not expand a leaf into a node over one that does. It must exceed the
  # depth of any id tree you will ever build; 2^32 leaves no realistic doubt.
  @expand_cost Bitwise.bsl(1, 32)

  @doc """
  Normalizes one node whose children are already normalized.

      iex> ITC.Event.norm({2, 1, 1})
      3
      iex> ITC.Event.norm(3)
      3
      iex> ITC.Event.norm({2, {2, 1, 0}, 3})
      {4, {0, 1, 0}, 1}
  """
  @spec norm(t) :: t
  def norm(n) when is_integer(n), do: n
  def norm({n, m, m}) when is_integer(m), do: n + m

  def norm({n, l, r}) do
    m = min(min_of(l), min_of(r))
    {n + m, sink(l, m), sink(r, m)}
  end

  @doc """
  Normalizes a well-formed event tree bottom-up.

      iex> ITC.Event.normalize({1, {0, 2, 2}, {3, 0, 0}})
      {3, 0, 1}
  """
  @spec normalize(t) :: t
  def normalize({n, l, r}), do: norm({n, normalize(l), normalize(r)})
  def normalize(n) when is_integer(n) and n >= 0, do: n

  @doc """
  Adds `m` to every point of the tree.

  The result is a valid tree only while every point stays non-negative.
  Callers sink by at most the tree's minimum.
  """
  @spec lift(t, integer) :: integer | {integer, t, t}
  def lift(n, m) when is_integer(n), do: n + m
  def lift({n, l, r}, m), do: {n + m, l, r}

  @doc "Subtracts `m` from every point of the tree. See `lift/2`."
  @spec sink(t, integer) :: integer | {integer, t, t}
  def sink(e, m), do: lift(e, -m)

  @doc "Minimum value of a normalized tree."
  @spec min_of(t) :: non_neg_integer
  def min_of(n) when is_integer(n), do: n
  def min_of({n, _l, _r}), do: n

  @doc "Maximum value of the tree."
  @spec max_of(t) :: non_neg_integer
  def max_of(n) when is_integer(n), do: n
  def max_of({n, l, r}), do: n + max(max_of(l), max_of(r))

  @doc """
  Pointwise `<=`: true when every point of `a` is at most the same point of `b`.

  The comparison carries an accumulated offset down each side instead of
  calling `lift/2`, so it allocates nothing.

      iex> ITC.Event.leq?({0, 1, 0}, 1)
      true
      iex> ITC.Event.leq?({0, 1, 0}, {0, 0, 1})
      false
  """
  @spec leq?(t, t) :: boolean
  def leq?(a, b), do: leq(a, 0, b, 0)

  defp leq(n1, o1, n2, o2) when is_integer(n1) and is_integer(n2), do: n1 + o1 <= n2 + o2
  defp leq(n1, o1, {n2, _, _}, o2) when is_integer(n1), do: n1 + o1 <= n2 + o2

  defp leq({n1, l1, r1}, o1, n2, o2) when is_integer(n2) do
    b1 = n1 + o1
    b1 <= n2 + o2 and leq(l1, b1, n2, o2) and leq(r1, b1, n2, o2)
  end

  defp leq({n1, l1, r1}, o1, {n2, l2, r2}, o2) do
    b1 = n1 + o1
    b2 = n2 + o2
    b1 <= b2 and leq(l1, b1, l2, b2) and leq(r1, b1, r2, b2)
  end

  @doc """
  Pointwise maximum of two trees.

      iex> ITC.Event.join({0, 1, 0}, {0, 0, 1})
      1
  """
  @spec join(t, t) :: t
  def join(n1, n2) when is_integer(n1) and is_integer(n2), do: max(n1, n2)
  def join(n1, {_, _, _} = e2) when is_integer(n1), do: join({n1, 0, 0}, e2)
  def join({_, _, _} = e1, n2) when is_integer(n2), do: join(e1, {n2, 0, 0})
  def join({n1, _, _} = e1, {n2, _, _} = e2) when n1 > n2, do: join(e2, e1)

  def join({n1, l1, r1}, {n2, l2, r2}) do
    d = n2 - n1
    norm({n1, join(l1, lift(l2, d)), join(r1, lift(r2, d))})
  end

  @doc """
  Raises the owned part of `e` as far as possible without inventing history.

  Each owned region is lifted to the highest value it can reach while staying
  at or below the maximum of what is already recorded nearby. This collapses
  the tree where possible. When nothing can be raised, it returns `e`
  unchanged, and `ITC.event/1` falls back to `grow/2`.

  Both arguments must be normalized. On a non-normalized `e`, the result can
  differ from `e` only in representation, which `ITC.event/1` would then
  mistake for a recorded event.
  """
  @spec fill(Id.t(), t) :: t
  def fill(0, e), do: e
  def fill(1, e), do: max_of(e)
  def fill(_id, n) when is_integer(n), do: n

  def fill({1, ir}, {n, el, er}) do
    er1 = fill(ir, er)
    norm({n, max(max_of(el), min_of(er1)), er1})
  end

  def fill({il, 1}, {n, el, er}) do
    el1 = fill(il, el)
    norm({n, el1, max(max_of(er), min_of(el1))})
  end

  def fill({il, ir}, {n, el, er}), do: norm({n, fill(il, el), fill(ir, er)})

  @doc """
  Records one event by incrementing a single owned leaf.

  Returns `{tree, cost}`. Among the leaves it could increment, it picks the
  cheapest: first the fewest leaf-to-node expansions, then the shallowest.

  Only meaningful when `fill/2` returned `e` unchanged, which is how
  `ITC.event/1` calls it. `id` must be normalized and non-zero, and under the
  same id `1` with a tree-shaped `e` cannot occur (fill always collapses it),
  so that combination raises `FunctionClauseError`.
  """
  @spec grow(Id.t(), t) :: {t, non_neg_integer}
  def grow(1, n) when is_integer(n), do: {n + 1, 0}

  def grow({_, _} = id, n) when is_integer(n) do
    {e, c} = grow(id, {n, 0, 0})
    {e, c + @expand_cost}
  end

  def grow({0, ir}, {n, el, er}) do
    {er1, cr} = grow(ir, er)
    {{n, el, er1}, cr + 1}
  end

  def grow({il, 0}, {n, el, er}) do
    {el1, cl} = grow(il, el)
    {{n, el1, er}, cl + 1}
  end

  def grow({il, ir}, {n, el, er}) do
    {el1, cl} = grow(il, el)
    {er1, cr} = grow(ir, er)

    if cl < cr do
      {{n, el1, er}, cl + 1}
    else
      {{n, el, er1}, cr + 1}
    end
  end

  @doc """
  Returns true when `term` is a well-formed, normalized event tree.

  Use this on anything that did not come from this module's own operations.

      iex> ITC.Event.normal?({0, 1, 0})
      true
      iex> ITC.Event.normal?({0, 1, 1})
      false
      iex> ITC.Event.normal?({1, 2, 3})
      false
  """
  @spec normal?(term) :: boolean
  def normal?(n) when is_integer(n), do: n >= 0

  def normal?({n, l, r}) when is_integer(n) and n >= 0 do
    normal?(l) and normal?(r) and min(min_of(l), min_of(r)) == 0 and
      not (is_integer(l) and l == r)
  end

  def normal?(_), do: false

  @doc "Number of nodes in the tree."
  @spec node_count(t) :: pos_integer
  def node_count({_n, l, r}), do: 1 + node_count(l) + node_count(r)
  def node_count(_leaf), do: 1
end
