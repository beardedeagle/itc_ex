# Diagnostic workloads; timings vary by runtime and hardware.
import Bitwise

for rounds <- [10, 100, 1_000] do
  {a, b} =
    Enum.reduce(1..rounds, ITC.fork(ITC.seed()), fn _, {a, b} ->
      {a, child} = ITC.fork(a)
      {:ok, b} = ITC.join(b, child)
      {a, b}
    end)

  {ia, _} = ITC.to_tuple(a)
  {ib, _} = ITC.to_tuple(b)
  {:ok, 1} = ITC.Id.sum(ia, ib)

  IO.inspect(
    {rounds, ITC.node_count(a), ITC.node_count(b), byte_size(ITC.encode_compact(a)),
     byte_size(ITC.encode_compact(b))},
    label: "churn: rounds, nodes A/B, compact bytes A/B"
  )
end

for depth <- [500, 1_000, 2_000, 4_000, 5_000] do
  width = 48 * depth
  event = Enum.reduce(1..depth, 1 <<< width, fn _, child -> {1, 0, child} end)
  {:ok, stamp} = ITC.new(0, event)
  bin = ITC.encode(stamp)
  true = byte_size(bin) <= 65_536

  times =
    for _ <- 1..7 do
      :erlang.garbage_collect()
      {us, {:error, :counter_too_large}} = :timer.tc(fn -> ITC.decode(bin) end)
      us
    end

  IO.inspect({depth, width, byte_size(bin), Enum.min(times)},
    label: "default ETF rejection: depth, leaf bits, bytes, minimum decode microseconds"
  )
end

for depth <- [4_000, 8_000, 16_000, 32_000] do
  width = 2 * depth
  leaf = 1 <<< width
  event = Enum.reduce(1..depth, leaf, fn _, child -> {1, 0, child} end)
  spine = Enum.reduce(1..depth, 1, fn _, child -> {1, 0, child} end)

  # Large root offsets force wide arithmetic along the descendant spine.
  for {shape, event, limit} <- [
        {:large_leaf, event, leaf + depth},
        {:large_root_base, {leaf, 0, spine}, leaf + depth + 1}
      ] do
    {:ok, stamp} = ITC.new(1, event)
    bin = ITC.encode_compact(stamp)

    times =
      for _ <- 1..5 do
        :erlang.garbage_collect()

        {us, {:ok, ^stamp}} =
          :timer.tc(fn -> ITC.decode_compact(bin, max_counter: limit) end)

        us
      end

    {default_us, {:error, :counter_too_large}} = :timer.tc(fn -> ITC.decode_compact(bin) end)

    IO.inspect({shape, depth, width, byte_size(bin), Enum.min(times), default_us},
      label:
        "compact: shape, depth, counter bits, bytes, finite/default limit decode microseconds"
    )
  end
end
