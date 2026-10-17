defmodule ITCTest do
  use ExUnit.Case, async: true

  alias ITC.{Event, Id}

  doctest ITC
  doctest ITC.Id
  doctest ITC.Event

  defp stamp!(id, event) do
    {:ok, stamp} = ITC.new(id, event)
    stamp
  end

  defp tuples(stamps), do: Enum.map(stamps, &ITC.to_tuple/1)

  describe "fork/1" do
    test "splits ownership and copies history" do
      {a, b} = ITC.fork(ITC.event(ITC.seed()))
      assert tuples([a, b]) == [{{1, 0}, 1}, {{0, 1}, 1}]
      assert {:ok, joined} = ITC.join(a, b)
      assert ITC.to_tuple(joined) == {1, 1}
    end

    test "split follows the paper's cases" do
      assert Id.split(0) == {0, 0}
      assert Id.split({0, 1}) == {{0, {1, 0}}, {0, {0, 1}}}
      assert Id.split({1, 0}) == {{{1, 0}, 0}, {{0, 1}, 0}}
      assert Id.split({{1, 0}, 1}) == {{{1, 0}, 0}, {0, 1}}
    end
  end

  describe "event/1" do
    test "a forked half inflates only its own side" do
      {a, b} = ITC.fork(ITC.seed())
      assert ITC.to_tuple(ITC.event(a)) == {{1, 0}, {0, 1, 0}}
      assert ITC.to_tuple(ITC.event(b)) == {{0, 1}, {0, 0, 1}}
    end

    test "fill collapses history once the owner holds the whole interval" do
      {a, b} = ITC.fork(ITC.seed())
      {:ok, joined} = ITC.join(ITC.event(a), b)
      assert ITC.to_tuple(joined) == {1, {0, 1, 0}}
      assert ITC.to_tuple(ITC.event(joined)) == {1, 1}
    end

    test "fill raises an owned side to its neighbour before growing" do
      # Owns the right half; the left half already reached 1.
      assert ITC.to_tuple(ITC.event(stamp!({0, 1}, {0, 1, 0}))) == {{0, 1}, 1}
    end

    test "grow increments the shallowest owned leaf when fill cannot help" do
      # Owns the left half (a leaf at depth 1) and the left quarter of the
      # right half (a leaf at depth 2). Fill changes nothing, so grow picks
      # the cheaper, shallower leaf.
      id = {1, {1, 0}}
      event = {0, 0, {0, 1, 0}}
      assert Event.fill(id, event) == event
      assert ITC.to_tuple(ITC.event(stamp!(id, event))) == {id, {0, 1, {0, 1, 0}}}
    end

    test "grow expands a leaf only when no owned leaf exists at the current depth" do
      {a, _} = ITC.fork(ITC.seed())
      {aa, _} = ITC.fork(a)
      # Id {{1, 0}, 0} against a scalar history: the leaf must be expanded twice.
      assert ITC.to_tuple(ITC.event(aa)) == {{{1, 0}, 0}, {0, {0, 1, 0}, 0}}
    end

    test "raises on anonymous stamps" do
      {anon, _} = ITC.peek(ITC.seed())
      assert_raise ArgumentError, ~r/anonymous/, fn -> ITC.event(anon) end
    end
  end

  describe "the run from section 5.1 of the paper" do
    # Derived by hand from the paper's definitions, following the run it
    # describes: the seed forks into two; one side records an event and forks;
    # the other records two events; then one participant records an event while
    # the other two synchronise (join, then fork); finally a join simplifies the
    # id and the next event collapses the history to a single integer.
    test "every intermediate stamp" do
      seed = ITC.seed()
      assert ITC.to_tuple(seed) == {1, 0}

      {a, b} = ITC.fork(seed)
      assert tuples([a, b]) == [{{1, 0}, 0}, {{0, 1}, 0}]

      a = ITC.event(a)
      assert ITC.to_tuple(a) == {{1, 0}, {0, 1, 0}}

      {a, c} = ITC.fork(a)
      assert tuples([a, c]) == [{{{1, 0}, 0}, {0, 1, 0}}, {{{0, 1}, 0}, {0, 1, 0}}]

      b = b |> ITC.event() |> ITC.event()
      assert ITC.to_tuple(b) == {{0, 1}, {0, 0, 2}}

      a = ITC.event(a)
      assert ITC.to_tuple(a) == {{{1, 0}, 0}, {0, {1, 1, 0}, 0}}

      {:ok, {b, d}} = ITC.sync(b, c)
      assert tuples([b, d]) == [{{{0, 1}, 0}, {1, 0, 1}}, {{0, 1}, {1, 0, 1}}]

      {:ok, a} = ITC.join(a, b)
      # The ids {{1, 0}, 0} and {{0, 1}, 0} merge into {1, 0}.
      assert ITC.to_tuple(a) == {{1, 0}, {1, {0, 1, 0}, 1}}

      # The event fills the gap, leaving a single integer.
      assert ITC.to_tuple(ITC.event(a)) == {{1, 0}, 2}
    end
  end

  describe "join/2" do
    test "rejoining forked halves restores full ownership" do
      {a, b} = ITC.fork(ITC.seed())
      assert {:ok, joined} = ITC.join(ITC.event(a), ITC.event(b))
      assert ITC.to_tuple(joined) == {1, 1}
    end

    test "is commutative" do
      {a, b} = ITC.fork(ITC.seed())
      a = a |> ITC.event() |> ITC.event()
      b = ITC.event(b)
      assert ITC.join(a, b) == ITC.join(b, a)
    end

    test "reports overlapping ownership" do
      seed = ITC.seed()
      {left, _right} = ITC.fork(seed)
      assert ITC.join(seed, seed) == {:error, :overlapping_ids}
      assert ITC.join(seed, left) == {:error, :overlapping_ids}
    end

    test "catches a re-seeded participant instead of silently merging" do
      # Two independent seeds both own [0, 1): their events are indistinguishable.
      a = ITC.event(ITC.seed())
      b = ITC.event(ITC.seed())
      assert ITC.relation(a, b) == :eq
      assert ITC.join(a, b) == {:error, :overlapping_ids}
    end

    test "catches a parent kept alive after forking" do
      parent = ITC.seed()
      {child, _other} = ITC.fork(parent)
      assert ITC.join(ITC.event(parent), ITC.event(child)) == {:error, :overlapping_ids}

      {grandchild, _} = ITC.fork(child)

      assert ITC.join(ITC.event(child), grandchild |> ITC.event() |> ITC.event()) ==
               {:error, :overlapping_ids}
    end

    test "join!/2 raises OverlapError" do
      assert_raise ITC.OverlapError, ~r/overlapping ids/, fn ->
        ITC.join!(ITC.seed(), ITC.seed())
      end
    end

    test "anonymous stamps join freely and transfer no ownership" do
      {anon, stamp} = ITC.peek(ITC.event(ITC.seed()))
      assert {:ok, ^stamp} = ITC.join(stamp, anon)
      assert {:ok, joined} = ITC.join(anon, anon)
      assert ITC.anonymous?(joined)
    end
  end

  describe "relation/2" do
    test "independent events are concurrent" do
      {a, b} = ITC.fork(ITC.seed())
      assert ITC.relation(ITC.event(a), ITC.event(b)) == :concurrent
      assert ITC.concurrent?(ITC.event(a), ITC.event(b))
    end

    test "message passing orders sender before receiver" do
      {a, b} = ITC.fork(ITC.seed())
      {msg, a} = ITC.send_event(a)
      {:ok, b} = ITC.receive_event(b, msg)
      assert ITC.relation(a, b) == :lt
      assert ITC.relation(b, a) == :gt
      assert ITC.leq?(a, b)
      refute ITC.leq?(b, a)
    end

    test "identical histories are :eq regardless of id" do
      {a, b} = ITC.fork(ITC.event(ITC.seed()))
      assert ITC.relation(a, b) == :eq
    end
  end

  describe "sync/2" do
    test "equalises history and redistributes the combined id" do
      {a, b} = ITC.fork(ITC.seed())
      {:ok, {a2, b2}} = ITC.sync(ITC.event(a), ITC.event(b))
      assert ITC.relation(a2, b2) == :eq
      {ia, _} = ITC.to_tuple(a2)
      {ib, _} = ITC.to_tuple(b2)
      assert Id.sum(ia, ib) == {:ok, 1}
    end
  end

  describe "new/2, from_tuple/1, to_tuple/1 and valid?/1" do
    test "reject non-normalized and malformed trees" do
      assert ITC.new({0, 0}, 0) == {:error, :invalid_id}
      assert ITC.new(2, 0) == {:error, :invalid_id}
      assert ITC.new(1, -1) == {:error, :invalid_event}
      assert ITC.new(1, {0, 0, 0}) == {:error, :invalid_event}
      assert ITC.new(1, {0, 1, 1}) == {:error, :invalid_event}
      assert ITC.new(1, {1, 2, 3}) == {:error, :invalid_event}
      assert ITC.new(1, {1.0, 0, 1}) == {:error, :invalid_event}
      refute ITC.valid?(:not_a_stamp)
    end

    test "from_tuple/1 and to_tuple/1 round-trip the {id, event} representation" do
      stamp = stamp!({{1, 0}, 0}, {0, {1, 1, 0}, 0})
      assert ITC.from_tuple(ITC.to_tuple(stamp)) == {:ok, stamp}
      assert ITC.from_tuple({1, {0, 1, 1}}) == {:error, :invalid_event}
      assert ITC.from_tuple({1, 0, 0}) == {:error, :malformed}
    end

    test "valid?/1 flags hand-built structs that would silently lose events" do
      # Same history as {0, 0, 1}, written without normalizing. event/1 on this
      # struct changes only the representation, so no event would be recorded.
      bad = %ITC{id: {0, 1}, event: {0, 0, {0, 1, 1}}}
      refute ITC.valid?(bad)
      assert ITC.new({0, 1}, {0, 0, {0, 1, 1}}) == {:error, :invalid_event}
    end
  end

  describe "encode/1 and decode/2" do
    test "round-trip" do
      {a, _} = ITC.fork(ITC.seed())
      a = a |> ITC.event() |> ITC.event()
      assert ITC.decode(ITC.encode(a)) == {:ok, a}
    end

    test "equal stamps encode to equal bytes" do
      {a, b} = ITC.fork(ITC.seed())
      {:ok, x} = ITC.join(ITC.event(a), ITC.event(b))
      assert ITC.encode(x) == ITC.encode(stamp!(1, 1))
    end

    test "rejects non-normalized trees" do
      assert ITC.decode(:erlang.term_to_binary({1, {1, 1}, 0})) == {:error, :invalid_id}
      assert ITC.decode(:erlang.term_to_binary({1, 1, {0, 0, 0}})) == {:error, :invalid_event}
    end

    test "rejects unknown versions, wrong shapes, garbage and trailing bytes" do
      assert ITC.decode(:erlang.term_to_binary({2, 1, 0})) == {:error, :unsupported_version}
      assert ITC.decode(:erlang.term_to_binary({1, 1})) == {:error, :malformed}
      assert ITC.decode(:erlang.term_to_binary([1, 1, 0])) == {:error, :malformed}
      assert ITC.decode(<<1, 2, 3>>) == {:error, :malformed}
      assert ITC.decode(<<>>) == {:error, :malformed}
      assert ITC.decode(ITC.encode(ITC.seed()) <> <<0>>) == {:error, :malformed}
    end

    test "refuses to create atoms from untrusted input" do
      name = "itc_decode_atom_that_must_not_exist"
      # {1, <atom>, 0} in External Term Format with a SMALL_ATOM_UTF8_EXT atom.
      bin = <<131, 104, 3, 97, 1, 119, byte_size(name), name::binary, 97, 0>>
      assert ITC.decode(bin) == {:error, :malformed}
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "enforces a size limit before parsing" do
      assert ITC.decode(ITC.encode(ITC.seed()), max_bytes: 4) == {:error, :too_large}
    end

    test "rejects compressed terms before inflating them" do
      # ~4 KiB of zlib that inflates to a 2M-element list (32 MiB of heap).
      payload = :erlang.term_to_binary({1, 0, List.duplicate(0, 2_000_000)}, compressed: 9)
      assert byte_size(payload) < 65_536

      # Decode under an 8 MiB heap cap: inflating would get the process killed.
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false})
          exit({:result, ITC.decode(payload)})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:result, {:error, :malformed}}}, 5_000
    end

    test "rejects non-canonical encodings of a valid stamp" do
      # {1, 1, 0} with INTEGER_EXT (tag 98) where encode/1 writes SMALL_INTEGER_EXT.
      alt = <<131, 104, 3, 97, 1, 98, 1::32, 98, 0::32>>
      assert :erlang.binary_to_term(alt) == {1, 1, 0}
      assert ITC.decode(alt) == {:error, :non_canonical}
    end

    test "bounds counters" do
      big = Bitwise.bsl(1, 64)
      bin = :erlang.term_to_binary({1, 0, {0, big, 0}})
      assert ITC.decode(bin) == {:error, :counter_too_large}
      assert ITC.decode(bin, max_counter: :infinity) |> elem(0) == :ok

      assert ITC.decode(:erlang.term_to_binary({1, 1, 6}), max_counter: 5) ==
               {:error, :counter_too_large}

      # The bound applies to the counter a cell actually holds, not one node.
      bin = :erlang.term_to_binary({1, 1, {3, 3, 0}})
      assert ITC.decode(bin, max_counter: 5) == {:error, :counter_too_large}
      assert ITC.decode(bin, max_counter: 6) |> elem(0) == :ok
    end

    test "rejects invalid options" do
      bin = ITC.encode(ITC.seed())
      assert_raise ArgumentError, fn -> ITC.decode(bin, max_bytes: 0) end
      assert_raise ArgumentError, fn -> ITC.decode(bin, max_counter: -1) end
      assert_raise ArgumentError, fn -> ITC.decode(bin, bogus: 1) end
    end
  end

  describe "encode_compact/2 and decode_compact/2 (paper, appendix A)" do
    test "matches hand-computed encodings" do
      # enc_i(1) = 001, enc_e(0) = 1 0 00
      assert ITC.encode_compact(ITC.seed(), pad: false) == <<0b001::3, 0b1000::4>>

      # enc_i({1, 0}) = 10 001
      # enc_e({0, 1, 0}) = 0 01 enc_e(1), enc_e(1) = 1 0 01
      stamp = stamp!({1, 0}, {0, 1, 0})
      assert ITC.encode_compact(stamp, pad: false) == <<0b10001::5, 0b0011001::7>>
      assert ITC.encode_compact(stamp) == <<0b10001::5, 0b0011001::7, 0::4>>

      # enc_e(5) = 1 enc_n(5, 2) = 1 1 enc_n(1, 3) = 1 1 0 001
      assert ITC.encode_compact(stamp!(1, 5), pad: false) == <<0b001::3, 0b110001::6>>
    end

    test "round-trips with and without padding" do
      stamp = stamp!({{1, 0}, 1}, {2, {0, 7, 0}, 1000})

      for opts <- [[], [pad: false]] do
        assert ITC.decode_compact(ITC.encode_compact(stamp, opts)) == {:ok, stamp}
      end
    end

    test "rejects bad padding and trailing data" do
      bits = ITC.encode_compact(ITC.seed(), pad: false)
      assert ITC.decode_compact(<<bits::bitstring, 1::1>>) == {:error, :malformed}
      assert ITC.decode_compact(<<bits::bitstring, 0::1, 0::8>>) == {:error, :malformed}
      assert ITC.decode_compact(<<bits::bitstring, 0::1>>) |> elem(0) == :ok
    end

    test "accepts only the exact bitstring or the byte-aligned padding" do
      stamp = stamp!({1, 0}, {0, 1, 0})
      exact = ITC.encode_compact(stamp, pad: false)
      assert bit_size(exact) == 12

      accepted =
        Enum.filter(0..7, fn extra ->
          ITC.decode_compact(<<exact::bitstring, 0::size(extra)>>) == {:ok, stamp}
        end)

      # The exact 12 bits, or 4 zero bits of padding to reach 16. Nothing else.
      assert accepted == [0, 4]
    end

    test "rejects a non-boolean :pad" do
      assert_raise ArgumentError, ~r/:pad must be a boolean/, fn ->
        ITC.encode_compact(ITC.seed(), pad: :yes)
      end

      assert_raise ArgumentError, fn -> ITC.encode_compact(ITC.seed(), pad: nil) end
    end

    @tag timeout: 10_000
    test "encodes and decodes huge counters in linear time" do
      # A counter with ~2M bits needs a ~2M-bit integer prefix. Encoding that
      # prefix one bit at a time with bignum arithmetic takes minutes.
      n = Bitwise.bsl(1, 2_000_000) + 12_345
      stamp = stamp!(1, n)
      bin = ITC.encode_compact(stamp)
      assert byte_size(bin) > 500_000

      assert ITC.decode_compact(bin, max_counter: :infinity, max_bytes: 1_000_000) ==
               {:ok, stamp}
    end

    test "rejects truncated and garbled input" do
      bits = ITC.encode_compact(stamp!({1, 0}, {0, 1, 0}), pad: false)

      for size <- 0..(bit_size(bits) - 1) do
        <<prefix::bitstring-size(^size), _::bitstring>> = bits
        assert ITC.decode_compact(prefix) == {:error, :malformed}
      end

      # A node's base must be a number; here it is another node.
      assert ITC.decode_compact(<<0b001::3, 0b0111::4, 0b000::3, 0b1000::4>>) ==
               {:error, :malformed}
    end

    test "rejects non-canonical encodings and non-normalized trees" do
      # {0, 0, 1} written with the general (n, l, r) form instead of (0, 0, r).
      general = <<0b001::3, 0b0111::4, 0b1000::4, 0b1000::4, 0b1001::4>>
      assert ITC.decode_compact(general) == {:error, :non_canonical}

      # {0, 1, 1} is not normalized.
      assert ITC.decode_compact(<<0b001::3, 0b010::3, 0b1001::4, 0b1001::4>>) ==
               {:error, :invalid_event}

      # {1, 1} is not normalized.
      assert ITC.decode_compact(<<0b11::2, 0b001::3, 0b001::3, 0b1000::4>>) ==
               {:error, :invalid_id}
    end

    test "bounds counters while parsing, in linear time" do
      assert ITC.decode_compact(ITC.encode_compact(stamp!(1, 6)), max_counter: 5) ==
               {:error, :counter_too_large}

      # A leaf followed by ~480k prefix bits. A decoder that sums 2^b per prefix
      # bit does quadratic bignum work here.
      hostile = <<0b001::3, 1::1, -1::size(60_000 * 8)>>
      assert ITC.decode_compact(hostile) == {:error, :counter_too_large}
      assert ITC.decode_compact(hostile, max_counter: :infinity) == {:error, :malformed}
    end

    test "enforces a size limit before parsing" do
      assert ITC.decode_compact(<<0::size(560_000)>>) == {:error, :too_large}
      assert ITC.decode_compact(<<0::9>>, max_bytes: 1) == {:error, :too_large}
    end

    test "is several times smaller than External Term Format" do
      stamp = stamp!({{1, 0}, {0, 1}}, {3, {0, 2, {0, 0, 4}}, {1, 0, 9}})
      assert byte_size(ITC.encode_compact(stamp)) * 4 < byte_size(ITC.encode(stamp))
    end
  end

  test "node_count/1 tracks tree size" do
    assert ITC.node_count(ITC.seed()) == 2
    {a, _} = ITC.fork(ITC.seed())
    assert ITC.node_count(ITC.event(a)) == 6
  end

  test "inspect" do
    assert inspect(ITC.seed()) == "#ITC<1 | 0>"
  end
end
