defmodule ITC.Compact do
  @moduledoc false
  # The binary encoding from Appendix A of the ITC paper, bit-compatible with
  # `itc:encode/1` and `itc:decode/1` in the reference implementations.
  #
  #   enc_i(0)       = <<0:2, 0:1>>
  #   enc_i(1)       = <<0:2, 1:1>>
  #   enc_i({0, i})  = <<1:2, enc_i(i)>>
  #   enc_i({i, 0})  = <<2:2, enc_i(i)>>
  #   enc_i({l, r})  = <<3:2, enc_i(l), enc_i(r)>>
  #
  #   enc_e({0, 0, r}) = <<0:1, 0:2, enc_e(r)>>
  #   enc_e({0, l, 0}) = <<0:1, 1:2, enc_e(l)>>
  #   enc_e({0, l, r}) = <<0:1, 2:2, enc_e(l), enc_e(r)>>
  #   enc_e({n, 0, r}) = <<0:1, 3:2, 0:1, 0:1, enc_e(n), enc_e(r)>>
  #   enc_e({n, l, 0}) = <<0:1, 3:2, 0:1, 1:1, enc_e(n), enc_e(l)>>
  #   enc_e({n, l, r}) = <<0:1, 3:2, 1:1, enc_e(n), enc_e(l), enc_e(r)>>
  #   enc_e(n)         = <<1:1, enc_n(n, 2)>>
  #
  #   enc_n(n, b) = <<0:1, n:b>>                     when n < 2^b
  #               = <<1:1, enc_n(n - 2^b, b + 1)>>   otherwise
  #
  # Encoders append to an accumulator so the runtime can extend the bitstring
  # in place instead of copying subtrees at every level.

  import Bitwise

  alias ITC.{Event, Id}

  @doc "Encodes an id tree and an event tree as Appendix A bits."
  @spec encode(Id.t(), Event.t()) :: bitstring
  def encode(id, event), do: event_bits(event, id_bits(id, <<>>))

  defp id_bits(0, acc), do: <<acc::bitstring, 0::2, 0::1>>
  defp id_bits(1, acc), do: <<acc::bitstring, 0::2, 1::1>>
  defp id_bits({0, i}, acc), do: id_bits(i, <<acc::bitstring, 1::2>>)
  defp id_bits({i, 0}, acc), do: id_bits(i, <<acc::bitstring, 2::2>>)
  defp id_bits({l, r}, acc), do: id_bits(r, id_bits(l, <<acc::bitstring, 3::2>>))

  defp event_bits({0, 0, r}, acc), do: event_bits(r, <<acc::bitstring, 0::1, 0::2>>)
  defp event_bits({0, l, 0}, acc), do: event_bits(l, <<acc::bitstring, 0::1, 1::2>>)

  defp event_bits({0, l, r}, acc),
    do: event_bits(r, event_bits(l, <<acc::bitstring, 0::1, 2::2>>))

  defp event_bits({n, 0, r}, acc),
    do: event_bits(r, number_bits(n, <<acc::bitstring, 0::1, 3::2, 0::1, 0::1>>))

  defp event_bits({n, l, 0}, acc),
    do: event_bits(l, number_bits(n, <<acc::bitstring, 0::1, 3::2, 0::1, 1::1>>))

  defp event_bits({n, l, r}, acc),
    do: event_bits(r, event_bits(l, number_bits(n, <<acc::bitstring, 0::1, 3::2, 1::1>>)))

  defp event_bits(n, acc) when is_integer(n), do: number_bits(n, acc)

  # enc_n(n, 2) in closed form. Unrolling the recursion: after k prefix 1-bits
  # the offset is 2^(k+2) - 4 and the payload width is k + 2, and k is the
  # smallest value with n < 2^(k+3) - 4, i.e. k = bit_length(n + 4) - 3.
  # Computing k directly keeps encoding linear in the size of n; the literal
  # recursion does one bignum shift and subtraction per prefix bit, which is
  # quadratic for huge counters.
  defp number_bits(n, acc) when n < 4, do: <<acc::bitstring, 1::1, 0::1, n::2>>

  defp number_bits(n, acc) do
    k = bit_length(n + 4) - 3
    width = k + 2
    <<acc::bitstring, 1::1, bsl(1, k) - 1::size(k), 0::1, n + 4 - bsl(1, width)::size(width)>>
  end

  @doc false
  @spec bit_length(pos_integer) :: pos_integer
  def bit_length(n) when n < 256, do: bits_in_byte(n)

  def bit_length(n) do
    <<first, _::binary>> = bytes = :binary.encode_unsigned(n)
    8 * (byte_size(bytes) - 1) + bits_in_byte(first)
  end

  defp bits_in_byte(b) when b < 2, do: 1
  defp bits_in_byte(b), do: 1 + bits_in_byte(bsr(b, 1))

  @doc """
  Decodes Appendix A bits into `{id, event, padding}`.

  Raises nothing. Returns `{:error, reason}` for truncated or garbled input
  and for any stored integer above `max_counter`. The caller validates normal
  form, canonical encoding and padding.

  Integers are decoded without the reference implementation's per-bit bignum
  accumulation: the run of prefix bits is counted first and bounded by
  `max_counter`, so adversarial input costs time linear in its length.
  """
  @spec decode(bitstring, non_neg_integer | :infinity) ::
          {:ok, Id.t(), Event.t(), bitstring} | {:error, :malformed | :counter_too_large}
  def decode(bits, max_counter) do
    limits = {max_counter, max_prefix(max_counter)}
    {id, rest} = dec_id(bits)
    {event, rest} = dec_event(rest, limits)
    {:ok, id, event, rest}
  catch
    :throw, {__MODULE__, reason} -> {:error, reason}
  end

  # After k prefix 1-bits the smallest representable value is 2^(k+2) - 4, so
  # at most bit_length(max + 4) - 3 prefix bits can lead to a value <= max.
  defp max_prefix(:infinity), do: :infinity
  defp max_prefix(max), do: bit_length(max + 4) - 3

  defp dec_id(<<0::2, 0::1, rest::bitstring>>), do: {0, rest}
  defp dec_id(<<0::2, 1::1, rest::bitstring>>), do: {1, rest}

  defp dec_id(<<1::2, rest::bitstring>>) do
    {i, rest} = dec_id(rest)
    {{0, i}, rest}
  end

  defp dec_id(<<2::2, rest::bitstring>>) do
    {i, rest} = dec_id(rest)
    {{i, 0}, rest}
  end

  defp dec_id(<<3::2, rest::bitstring>>) do
    {l, rest} = dec_id(rest)
    {r, rest} = dec_id(rest)
    {{l, r}, rest}
  end

  defp dec_id(_), do: fail(:malformed)

  defp dec_event(<<0::1, 0::2, rest::bitstring>>, limits) do
    {r, rest} = dec_event(rest, limits)
    {{0, 0, r}, rest}
  end

  defp dec_event(<<0::1, 1::2, rest::bitstring>>, limits) do
    {l, rest} = dec_event(rest, limits)
    {{0, l, 0}, rest}
  end

  defp dec_event(<<0::1, 2::2, rest::bitstring>>, limits) do
    {l, rest} = dec_event(rest, limits)
    {r, rest} = dec_event(rest, limits)
    {{0, l, r}, rest}
  end

  defp dec_event(<<0::1, 3::2, 0::1, 0::1, rest::bitstring>>, limits) do
    {n, rest} = dec_leaf(rest, limits)
    {r, rest} = dec_event(rest, limits)
    {{n, 0, r}, rest}
  end

  defp dec_event(<<0::1, 3::2, 0::1, 1::1, rest::bitstring>>, limits) do
    {n, rest} = dec_leaf(rest, limits)
    {l, rest} = dec_event(rest, limits)
    {{n, l, 0}, rest}
  end

  defp dec_event(<<0::1, 3::2, 1::1, rest::bitstring>>, limits) do
    {n, rest} = dec_leaf(rest, limits)
    {l, rest} = dec_event(rest, limits)
    {r, rest} = dec_event(rest, limits)
    {{n, l, r}, rest}
  end

  defp dec_event(bits, limits), do: dec_leaf(bits, limits)

  # A leaf is <<1:1, enc_n(n, 2)>>. The base of a node is also a leaf; unlike
  # the reference decoder, a subtree in that position is rejected.
  defp dec_leaf(<<1::1, rest::bitstring>>, limits), do: dec_number(rest, 0, limits)
  defp dec_leaf(_, _limits), do: fail(:malformed)

  # After k prefix 1-bits the value offset is sum(2^j, j = 2..k+1) = 2^(k+2) - 4
  # and the payload width is k + 2 bits. Only small integers are touched while
  # counting, so a long run of prefix bits costs linear time.
  defp dec_number(<<1::1, _::bitstring>>, k, {_max, k}), do: fail(:counter_too_large)
  defp dec_number(<<1::1, rest::bitstring>>, k, limits), do: dec_number(rest, k + 1, limits)

  defp dec_number(<<0::1, rest::bitstring>>, k, {max, _}) do
    width = k + 2

    case rest do
      <<x::size(^width), rest::bitstring>> ->
        n = bsl(1, width) - 4 + x
        if max != :infinity and n > max, do: fail(:counter_too_large)
        {n, rest}

      _ ->
        fail(:malformed)
    end
  end

  defp dec_number(_, _k, _limits), do: fail(:malformed)

  @spec fail(:malformed | :counter_too_large) :: no_return
  defp fail(reason), do: throw({__MODULE__, reason})
end
