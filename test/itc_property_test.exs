defmodule ITC.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ITC.Generators

  alias ITC.{Event, Id, Spec}

  @max_replicas 16
  @runs 1_000

  # ---------------------------------------------------------------------------
  # Model-based test: random fork / event / join / send / deliver / sync, checked
  # after every step against a ground-truth oracle. Each replica carries the
  # set of event ids in its causal past; ITC must agree with set inclusion.
  # The same traffic also runs through the paper-literal spec, which must
  # produce identical stamps.
  # ---------------------------------------------------------------------------

  property "stamps track causal history exactly under arbitrary traffic" do
    check all(commands <- list_of(command(), max_length: 80), max_runs: 400) do
      run_model(commands)
    end
  end

  test "delayed and repeated messages survive sender retirement and sync" do
    commands = [
      {:fork, 0},
      {:send, 0},
      {:send, 0},
      {:join, 0, 0},
      {:fork, 0},
      {:sync, 0, 0},
      {:deliver, 0, 0},
      {:deliver, 1, 1},
      {:deliver, 0, 1},
      {:deliver, 1, 1}
    ]

    run_model(commands)
  end

  defp run_model(commands) do
    Enum.reduce(commands, {[{ITC.seed(), {1, 0}, MapSet.new()}], [], 0}, fn cmd, state ->
      state = step(cmd, state)
      assert_invariants(state)
      state
    end)
  end

  defp command do
    frequency([
      {4, tuple({constant(:event), non_negative_integer()})},
      {2, tuple({constant(:fork), non_negative_integer()})},
      {2, tuple({constant(:join), non_negative_integer(), non_negative_integer()})},
      {3, tuple({constant(:send), non_negative_integer()})},
      {3, tuple({constant(:deliver), non_negative_integer(), non_negative_integer()})},
      {2, tuple({constant(:sync), non_negative_integer(), non_negative_integer()})}
    ])
  end

  defp step({:event, i}, {pool, pending, next}) do
    idx = rem(i, length(pool))
    {stamp, spec, hist} = Enum.at(pool, idx)
    advanced = ITC.event(stamp)

    assert ITC.relation(stamp, advanced) == :lt

    {List.replace_at(pool, idx, {advanced, Spec.event(spec), MapSet.put(hist, next)}), pending,
     next + 1}
  end

  defp step({:fork, _i}, {pool, _pending, _next} = state) when length(pool) >= @max_replicas,
    do: state

  defp step({:fork, i}, {pool, pending, next}) do
    idx = rem(i, length(pool))
    {stamp, spec, hist} = Enum.at(pool, idx)
    {a, b} = ITC.fork(stamp)
    {sa, sb} = Spec.fork(spec)
    {List.replace_at(pool, idx, {a, sa, hist}) ++ [{b, sb, hist}], pending, next}
  end

  defp step({op, _i, _j}, {[_], _pending, _next} = state) when op in [:join, :sync],
    do: state

  defp step({:join, i, j}, {pool, pending, next}) do
    {ia, ib} = distinct_indices(i, j, length(pool))
    {sa, pa, ha} = Enum.at(pool, ia)
    {sb, pb, hb} = Enum.at(pool, ib)
    assert {:ok, joined} = ITC.join(sa, sb)

    rest = pool |> List.delete_at(max(ia, ib)) |> List.delete_at(min(ia, ib))
    {[{joined, Spec.join(pa, pb), MapSet.union(ha, hb)} | rest], pending, next}
  end

  defp step({:send, i}, {pool, pending, next}) do
    from = rem(i, length(pool))
    {sender, ps, hs} = Enum.at(pool, from)
    {msg, sender} = ITC.send_event(sender)
    hs = MapSet.put(hs, next)
    {spec_msg, ps} = ps |> Spec.event() |> Spec.peek()

    {List.replace_at(pool, from, {sender, ps, hs}),
     Enum.take([{msg, spec_msg, hs} | pending], 16), next + 1}
  end

  defp step({:deliver, _i, _j}, {_pool, [], _next} = state), do: state

  defp step({:deliver, i, j}, {pool, pending, next}) do
    {msg, spec_msg, hs} = Enum.at(pending, rem(i, length(pending)))
    to = rem(j, length(pool))
    {receiver, pr, hr} = Enum.at(pool, to)
    assert {:ok, receiver} = ITC.receive_event(receiver, msg)
    hr = hr |> MapSet.union(hs) |> MapSet.put(next)
    pr = pr |> Spec.join(spec_msg) |> Spec.event()

    {List.replace_at(pool, to, {receiver, pr, hr}), pending, next + 1}
  end

  defp step({:sync, i, j}, {pool, pending, next}) do
    {ia, ib} = distinct_indices(i, j, length(pool))
    {a, pa, ha} = Enum.at(pool, ia)
    {b, pb, hb} = Enum.at(pool, ib)
    assert {:ok, {a, b}} = ITC.sync(a, b)
    {pa, pb} = pa |> Spec.join(pb) |> Spec.fork()
    hist = MapSet.union(ha, hb)

    {pool |> List.replace_at(ia, {a, pa, hist}) |> List.replace_at(ib, {b, pb, hist}), pending,
     next}
  end

  defp distinct_indices(i, j, n) do
    a = rem(i, n)
    {a, rem(a + 1 + rem(j, n - 1), n)}
  end

  defp assert_invariants({pool, pending, _next}) do
    stamps = Enum.map(pool, &elem(&1, 0))

    # The live ids partition [0, 1) exactly: nothing lost, nothing duplicated.
    total =
      Enum.reduce_while(stamps, {:ok, 0}, fn s, {:ok, acc} ->
        {id, _} = ITC.to_tuple(s)

        case Id.sum(acc, id) do
          {:ok, _} = ok -> {:cont, ok}
          error -> {:halt, error}
        end
      end)

    assert total == {:ok, 1}

    for {s, spec, _} <- pool ++ pending do
      assert ITC.to_tuple(s) == spec
      assert ITC.valid?(s), "not normalized: #{inspect(s)}"
      assert ITC.decode(ITC.encode(s)) == {:ok, s}
      assert ITC.decode_compact(ITC.encode_compact(s)) == {:ok, s}
    end

    for {sa, _, ha} <- pool ++ pending, {sb, _, hb} <- pool ++ pending do
      assert ITC.leq?(sa, sb) == MapSet.subset?(ha, hb),
             "leq?(#{inspect(sa)}, #{inspect(sb)}) disagrees with the oracle"
    end
  end

  # ---------------------------------------------------------------------------
  # Differential properties against the paper-literal spec on arbitrary
  # normalized inputs, including states no traffic would reach.
  # ---------------------------------------------------------------------------

  property "event/1 matches the paper exactly" do
    check all(stamp <- owning_stamp(), max_runs: @runs) do
      assert ITC.to_tuple(ITC.event(stamp)) == Spec.event(ITC.to_tuple(stamp))
    end
  end

  property "join/2 matches the paper exactly" do
    check all({ia, ib} <- disjoint_ids(), ea <- event_tree(), eb <- event_tree(), max_runs: @runs) do
      {:ok, a} = ITC.new(ia, ea)
      {:ok, b} = ITC.new(ib, eb)
      assert {:ok, joined} = ITC.join(a, b)
      assert ITC.to_tuple(joined) == Spec.join({ia, ea}, {ib, eb})
    end
  end

  property "fork/1, peek/1 and leq?/2 match the paper exactly" do
    check all(a <- stamp(), b <- stamp(), max_runs: @runs) do
      {x, y} = ITC.fork(a)
      assert {ITC.to_tuple(x), ITC.to_tuple(y)} == Spec.fork(ITC.to_tuple(a))

      {anon, same} = ITC.peek(a)
      assert {ITC.to_tuple(anon), ITC.to_tuple(same)} == Spec.peek(ITC.to_tuple(a))

      {_, ea} = ITC.to_tuple(a)
      {_, eb} = ITC.to_tuple(b)
      assert ITC.leq?(a, b) == Spec.leq(ea, eb)
    end
  end

  property "the compact encoding matches appendix A exactly" do
    check all(stamp <- stamp(), max_runs: @runs) do
      assert ITC.encode_compact(stamp, pad: false) == Spec.encode(ITC.to_tuple(stamp))
    end
  end

  property "the closed-form integer encoding matches appendix A for any counter" do
    big = one_of([integer(0..20), integer(0..100_000), map(integer(0..300), &Bitwise.bsl(1, &1))])

    check all(n <- big, delta <- integer(-3..3), max_runs: @runs) do
      n = max(n + delta, 0)
      {:ok, stamp} = ITC.new(1, n)
      assert ITC.encode_compact(stamp, pad: false) == Spec.encode({1, n})
      assert ITC.decode_compact(ITC.encode_compact(stamp), max_counter: :infinity) == {:ok, stamp}
    end
  end

  property "both wire formats round-trip and are canonical" do
    check all(stamp <- stamp(), max_runs: @runs) do
      etf = ITC.encode(stamp)
      bits = ITC.encode_compact(stamp, pad: false)
      padded = ITC.encode_compact(stamp)

      assert ITC.decode(etf) == {:ok, stamp}
      assert ITC.decode_compact(bits) == {:ok, stamp}
      assert ITC.decode_compact(padded) == {:ok, stamp}
      assert is_binary(padded) and bit_size(padded) - bit_size(bits) < 8
    end
  end

  property "decode_compact/2 never crashes on arbitrary input" do
    check all(bits <- bitstring(max_length: 256), max_runs: @runs) do
      case ITC.decode_compact(bits) do
        {:ok, stamp} -> assert ITC.encode_compact(stamp, pad: false) == trim_padding(bits, stamp)
        {:error, reason} -> assert is_atom(reason)
      end
    end
  end

  property "decode/2 never crashes on arbitrary ETF bodies" do
    check all(body <- binary(max_length: 256), max_runs: @runs) do
      bin = <<131, 104, 3, 97, 1, body::binary>>

      case ITC.decode(bin) do
        {:ok, stamp} -> assert ITC.encode(stamp) == bin
        {:error, reason} -> assert is_atom(reason)
      end
    end
  end

  defp trim_padding(bits, stamp) do
    size = bit_size(ITC.encode_compact(stamp, pad: false))
    <<prefix::bitstring-size(^size), _::bitstring>> = bits
    prefix
  end

  # ---------------------------------------------------------------------------
  # Semantic oracles for arbitrary trees. An id is a set of cells
  # and an event tree is a function over cells; both are expanded to an
  # explicit 2^depth grid and compared cell by cell.
  # ---------------------------------------------------------------------------

  defp depth({l, r}), do: 1 + max(depth(l), depth(r))
  defp depth({_n, l, r}), do: 1 + max(depth(l), depth(r))
  defp depth(_leaf), do: 0

  defp cells(0, d), do: List.duplicate(false, Bitwise.bsl(1, d))
  defp cells(1, d), do: List.duplicate(true, Bitwise.bsl(1, d))
  defp cells({l, r}, d), do: cells(l, d - 1) ++ cells(r, d - 1)

  defp values(n, d) when is_integer(n), do: List.duplicate(n, Bitwise.bsl(1, d))

  defp values({n, l, r}, d) do
    Enum.map(values(l, d - 1) ++ values(r, d - 1), &(&1 + n))
  end

  property "id normalization preserves membership and yields normal form" do
    raw =
      Enum.reduce(1..5, member_of([0, 1]), fn _, child ->
        one_of([member_of([0, 1]), tuple({child, child})])
      end)

    check all(id <- raw, max_runs: @runs) do
      normalized = Id.normalize(id)
      assert Id.normal?(normalized)
      assert cells(normalized, depth(id)) == cells(id, depth(id))
    end
  end

  property "event normalization preserves cell values and yields normal form" do
    raw =
      Enum.reduce(1..5, integer(0..4), fn _, child ->
        one_of([integer(0..4), tuple({integer(0..3), child, child})])
      end)

    check all(event <- raw, max_runs: @runs) do
      normalized = Event.normalize(event)
      assert Event.normal?(normalized)
      assert values(normalized, depth(event)) == values(event, depth(event))
    end
  end

  property "split yields disjoint halves that sum back to the original" do
    check all(id <- id_tree(), max_runs: @runs) do
      {a, b} = Id.split(id)
      d = Enum.max([depth(id), depth(a), depth(b)])

      for {ca, cb} <- Enum.zip(cells(a, d), cells(b, d)), do: refute(ca and cb)

      assert Enum.zip_with(cells(a, d), cells(b, d), &(&1 or &2)) == cells(id, d)
      assert Id.sum(a, b) == {:ok, id}
      assert Id.normal?(a) and Id.normal?(b)
    end
  end

  property "sum is cell union and fails exactly when ids overlap" do
    check all(a <- id_tree(), b <- id_tree(), max_runs: @runs) do
      d = max(depth(a), depth(b))
      overlap? = Enum.zip_with(cells(a, d), cells(b, d), &(&1 and &2)) |> Enum.any?()

      case Id.sum(a, b) do
        {:error, :overlapping_ids} ->
          assert overlap?

        {:ok, s} ->
          refute overlap?
          assert Id.normal?(s)
          d = max(d, depth(s))
          assert cells(s, d) == Enum.zip_with(cells(a, d), cells(b, d), &(&1 or &2))
      end
    end
  end

  property "event join is pointwise max and leq? is pointwise <=" do
    check all(a <- event_tree(), b <- event_tree(), max_runs: @runs) do
      j = Event.join(a, b)
      d = Enum.max([depth(a), depth(b), depth(j)])
      va = values(a, d)
      vb = values(b, d)

      assert Event.normal?(j)
      assert values(j, d) == Enum.zip_with(va, vb, &max/2)
      assert Event.leq?(a, b) == Enum.all?(Enum.zip_with(va, vb, &(&1 <= &2)))
    end
  end

  property "normal form is canonical: semantically equal trees are identical" do
    check all(a <- event_tree(), b <- event_tree(), max_runs: @runs) do
      if Event.leq?(a, b) and Event.leq?(b, a), do: assert(a == b)
      assert Event.leq?(a, b) == (Event.join(a, b) == b)
      assert Event.join(a, b) == Event.join(b, a)
      assert Event.join(a, a) == a
    end
  end

  property "event join is associative" do
    check all(a <- event_tree(), b <- event_tree(), c <- event_tree(), max_runs: @runs) do
      assert Event.join(Event.join(a, b), c) == Event.join(a, Event.join(b, c))
    end
  end

  property "an event inflates owned cells and leaves every other cell untouched" do
    check all(stamp <- owning_stamp(), max_runs: @runs) do
      {id, e} = ITC.to_tuple(stamp)
      {_, e2} = stamp |> ITC.event() |> ITC.to_tuple()
      d = Enum.max([depth(id), depth(e), depth(e2)])
      owned = cells(id, d)
      before = values(e, d)
      after_ = values(e2, d)

      assert Event.normal?(e2)

      for {own?, x, y} <- Enum.zip([owned, before, after_]) do
        if own?, do: assert(y >= x), else: assert(y == x)
      end

      assert Enum.zip([owned, before, after_]) |> Enum.any?(fn {o, x, y} -> o and y > x end)
    end
  end
end
