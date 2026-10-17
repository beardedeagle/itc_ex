defmodule ITC.Spec do
  @moduledoc """
  The ITC paper transcribed literally, as an executable specification for
  differential tests. Section numbers refer to Almeida, Baquero & Fonte,
  "Interval Tree Clocks", OPODIS 2008.

  This deliberately does not share code or shortcuts with `lib/`:

    * `min/1` is the general recursive definition (5.2), not the
      normal-form shortcut;
    * `leq/2` lifts subtrees exactly as written (5.3.1), allocating as it goes;
    * `grow/2` uses the lexicographic `{expansions, depth}` cost that the paper
      says its constant N stands in for (5.3.4), so no constant is needed;
    * the Appendix A encoder builds a list of bits straight from the
      equations.

  Stamps are `{id, event}` tuples.
  """

  import Bitwise

  # 5.2 Normal form ------------------------------------------------------------

  def norm_id({0, 0}), do: 0
  def norm_id({1, 1}), do: 1
  def norm_id(i), do: i

  def norm_ev(n) when is_integer(n), do: n
  def norm_ev({n, m, m}) when is_integer(m), do: n + m

  def norm_ev({n, e1, e2}) do
    m = min(min_ev(e1), min_ev(e2))
    {n + m, sink(e1, m), sink(e2, m)}
  end

  def lift(n, m) when is_integer(n), do: n + m
  def lift({n, e1, e2}, m), do: {n + m, e1, e2}

  def sink(n, m) when is_integer(n), do: n - m
  def sink({n, e1, e2}, m), do: {n - m, e1, e2}

  def min_ev(n) when is_integer(n), do: n
  def min_ev({n, e1, e2}), do: n + min(min_ev(e1), min_ev(e2))

  def max_ev(n) when is_integer(n), do: n
  def max_ev({n, e1, e2}), do: n + max(max_ev(e1), max_ev(e2))

  # 5.3.1 Comparison -------------------------------------------------------------

  def leq(n1, n2) when is_integer(n1) and is_integer(n2), do: n1 <= n2
  def leq(n1, {n2, _l2, _r2}) when is_integer(n1), do: n1 <= n2

  def leq({n1, l1, r1}, n2) when is_integer(n2),
    do: n1 <= n2 and leq(lift(l1, n1), n2) and leq(lift(r1, n1), n2)

  def leq({n1, l1, r1}, {n2, l2, r2}),
    do: n1 <= n2 and leq(lift(l1, n1), lift(l2, n2)) and leq(lift(r1, n1), lift(r2, n2))

  # 5.3.2 Fork ---------------------------------------------------------------------

  def fork({i, e}) do
    {i1, i2} = split(i)
    {{i1, e}, {i2, e}}
  end

  def split(0), do: {0, 0}
  def split(1), do: {{1, 0}, {0, 1}}

  def split({0, i}) do
    {i1, i2} = split(i)
    {{0, i1}, {0, i2}}
  end

  def split({i, 0}) do
    {i1, i2} = split(i)
    {{i1, 0}, {i2, 0}}
  end

  def split({i1, i2}), do: {{i1, 0}, {0, i2}}

  def peek({i, e}), do: {{0, e}, {i, e}}

  # 5.3.3 Join -----------------------------------------------------------------------

  def join({i1, e1}, {i2, e2}), do: {sum(i1, i2), join_ev(e1, e2)}

  def sum(0, i), do: i
  def sum(i, 0), do: i
  def sum({l1, r1}, {l2, r2}), do: norm_id({sum(l1, l2), sum(r1, r2)})

  def join_ev(n1, n2) when is_integer(n1) and is_integer(n2), do: max(n1, n2)
  def join_ev(n1, {_, _, _} = e2) when is_integer(n1), do: join_ev({n1, 0, 0}, e2)
  def join_ev({_, _, _} = e1, n2) when is_integer(n2), do: join_ev(e1, {n2, 0, 0})
  def join_ev({n1, _, _} = e1, {n2, _, _} = e2) when n1 > n2, do: join_ev(e2, e1)

  def join_ev({n1, l1, r1}, {n2, l2, r2}),
    do: norm_ev({n1, join_ev(l1, lift(l2, n2 - n1)), join_ev(r1, lift(r2, n2 - n1))})

  # 5.3.4 Event ----------------------------------------------------------------------

  def event({i, e}) when i != 0 do
    case fill(i, e) do
      ^e ->
        {e1, _cost} = grow(i, e)
        {i, e1}

      filled ->
        {i, filled}
    end
  end

  def fill(0, e), do: e
  def fill(1, e), do: max_ev(e)
  def fill(_i, n) when is_integer(n), do: n

  def fill({1, ir}, {n, el, er}) do
    er1 = fill(ir, er)
    norm_ev({n, max(max_ev(el), min_ev(er1)), er1})
  end

  def fill({il, 1}, {n, el, er}) do
    el1 = fill(il, el)
    norm_ev({n, el1, max(max_ev(er), min_ev(el1))})
  end

  def fill({il, ir}, {n, el, er}), do: norm_ev({n, fill(il, el), fill(ir, er)})

  # Cost is {expansions, depth}, compared lexicographically.
  def grow(1, n) when is_integer(n), do: {n + 1, {0, 0}}

  def grow(i, n) when is_integer(n) do
    {e1, {x, d}} = grow(i, {n, 0, 0})
    {e1, {x + 1, d}}
  end

  def grow({0, ir}, {n, el, er}) do
    {er1, {x, d}} = grow(ir, er)
    {{n, el, er1}, {x, d + 1}}
  end

  def grow({il, 0}, {n, el, er}) do
    {el1, {x, d}} = grow(il, el)
    {{n, el1, er}, {x, d + 1}}
  end

  def grow({il, ir}, {n, el, er}) do
    {el1, {xl, dl} = cl} = grow(il, el)
    {er1, {xr, dr} = cr} = grow(ir, er)

    if cl < cr,
      do: {{n, el1, er}, {xl, dl + 1}},
      else: {{n, el, er1}, {xr, dr + 1}}
  end

  # Appendix A --------------------------------------------------------------------

  def encode({i, e}), do: bits_to_bitstring(enc_i(i) ++ enc_e(e))

  def enc_i(0), do: bits(0, 2) ++ bits(0, 1)
  def enc_i(1), do: bits(0, 2) ++ bits(1, 1)
  def enc_i({0, i}), do: bits(1, 2) ++ enc_i(i)
  def enc_i({i, 0}), do: bits(2, 2) ++ enc_i(i)
  def enc_i({il, ir}), do: bits(3, 2) ++ enc_i(il) ++ enc_i(ir)

  def enc_e({0, 0, er}), do: bits(0, 1) ++ bits(0, 2) ++ enc_e(er)
  def enc_e({0, el, 0}), do: bits(0, 1) ++ bits(1, 2) ++ enc_e(el)
  def enc_e({0, el, er}), do: bits(0, 1) ++ bits(2, 2) ++ enc_e(el) ++ enc_e(er)

  def enc_e({n, 0, er}),
    do: bits(0, 1) ++ bits(3, 2) ++ bits(0, 1) ++ bits(0, 1) ++ enc_e(n) ++ enc_e(er)

  def enc_e({n, el, 0}),
    do: bits(0, 1) ++ bits(3, 2) ++ bits(0, 1) ++ bits(1, 1) ++ enc_e(n) ++ enc_e(el)

  def enc_e({n, el, er}),
    do: bits(0, 1) ++ bits(3, 2) ++ bits(1, 1) ++ enc_e(n) ++ enc_e(el) ++ enc_e(er)

  def enc_e(n) when is_integer(n), do: bits(1, 1) ++ enc_n(n, 2)

  def enc_n(n, b) do
    if n < 1 <<< b,
      do: bits(0, 1) ++ bits(n, b),
      else: bits(1, 1) ++ enc_n(n - (1 <<< b), b + 1)
  end

  # n:b as a list of b bits, most significant first.
  defp bits(n, b), do: for(k <- (b - 1)..0//-1, do: n >>> k &&& 1)

  defp bits_to_bitstring(list), do: for(bit <- list, into: <<>>, do: <<bit::1>>)
end
