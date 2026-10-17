defmodule ITC do
  @moduledoc """
  Interval Tree Clocks (Almeida, Baquero & Fonte, OPODIS 2008).

  A stamp has two parts:

    * an **id**: the share of the interval [0, 1) this participant owns;
    * an **event** tree: the causal history it has seen.

  Participants are created with `fork/1` and retired with `join/2`. No
  globally unique identifiers are needed, and stamp size follows the set of
  participants that are currently live, not every participant that ever
  existed.

      iex> {a, b} = ITC.fork(ITC.seed())
      iex> a = ITC.event(a)
      iex> b = ITC.event(b)
      iex> ITC.relation(a, b)
      :concurrent
      iex> {:ok, merged} = ITC.join(a, b)
      iex> merged
      #ITC<1 | 1>

  ## Constructing stamps

  `t()` is opaque. Obtain stamps only from `seed/0`, `fork/1`, `peek/1`,
  `join/2`, `event/1`, or from the validating constructors `new/2`,
  `from_tuple/1`, `decode/2` and `decode_compact/2`.

  Every operation assumes both trees are in the paper's normal form; that is
  what makes structural comparison meaningful. A hand-built `%ITC{}` with a
  non-normalized tree makes `event/1` silently record nothing and makes
  comparisons wrong. Check untrusted values with `valid?/1`.

  ## Ownership rules

  The id is a capability. Every guarantee depends on it never being
  duplicated.

    * Start a system from exactly one `seed/0` and derive every other stamp
      from it with `fork/1`. Two independent seeds own the same space, so
      their events cannot be told apart.
    * After a fork, keep only the two children and discard the parent.
    * A restarted participant resumes from its last durable stamp, or gets a
      new fork from a live holder. It never seeds again.
    * Reclaim a crashed participant's id (by joining its last durable stamp)
      only once nothing can still be using that id. Decide the death through
      consensus and fence the old holder.

  `join/2` checks for overlapping ids. In a correct system, overlap means one
  of these rules was broken; the usual cause is a zombie still holding an id
  that was reclaimed.

  ## Error conventions

  Programmer errors raise, for example recording an event on an anonymous
  stamp or passing an unknown option. Conditions that can come from
  distributed state return tagged tuples: overlapping ids, and input that
  fails to decode or validate.

  ## Wire formats

    * `encode/1` / `decode/2`: External Term Format. Fast on the BEAM.
    * `encode_compact/2` / `decode_compact/2`: the bit encoding from
      Appendix A of the paper, about 5x smaller and bit-compatible with
      `itc:encode/1` and `itc:decode/1` in the Erlang reference
      implementations.

  Both decoders accept only canonical encodings of normalized stamps, so for
  any accepted binary, byte equality is stamp equality. (`decode_compact/2`
  also accepts the unpadded bitstring form, which is not a binary.) Both bound input size
  before parsing and bound counter values (see `decode/2`).

  ## Interoperating with the Erlang implementations

  The paper authors' Erlang reference implementation represents a stamp as an
  `{id, event}` tuple using the same trees. Convert with `to_tuple/1` and
  `from_tuple/1`; exchange bytes with `encode_compact/2` and
  `decode_compact/2`.
  """

  alias ITC.{Compact, Event, Id}

  @enforce_keys [:id, :event]
  defstruct [:id, :event]

  @opaque t :: %__MODULE__{id: Id.t(), event: Event.t()}

  @typedoc "Causal relation between two stamps' histories."
  @type relation :: :eq | :lt | :gt | :concurrent

  @type decode_error ::
          :too_large
          | :malformed
          | :unsupported_version
          | :invalid_id
          | :invalid_event
          | :non_canonical
          | :counter_too_large

  @type decode_opt :: {:max_bytes, pos_integer} | {:max_counter, non_neg_integer | :infinity}

  @wire_version 1
  @default_max_bytes 65_536
  @default_max_counter Bitwise.bsl(1, 64) - 1

  @doc """
  The initial stamp: owns the whole interval, has seen nothing.

      iex> ITC.seed()
      #ITC<1 | 0>
  """
  @spec seed() :: t
  def seed, do: %__MODULE__{id: 1, event: 0}

  @doc """
  Builds a stamp from raw trees after validating that both are normalized.

      iex> {:ok, stamp} = ITC.new({1, 0}, {0, 1, 0})
      iex> stamp
      #ITC<{1, 0} | {0, 1, 0}>
      iex> ITC.new({1, 1}, 0)
      {:error, :invalid_id}
  """
  @spec new(term, term) :: {:ok, t} | {:error, :invalid_id | :invalid_event}
  def new(id, event) do
    cond do
      not Id.normal?(id) -> {:error, :invalid_id}
      not Event.normal?(event) -> {:error, :invalid_event}
      true -> {:ok, %__MODULE__{id: id, event: event}}
    end
  end

  @doc """
  Builds a stamp from an `{id, event}` tuple, the representation used by the
  Erlang reference implementation, after validation.

      iex> {:ok, stamp} = ITC.from_tuple({{0, 1}, {0, 0, 2}})
      iex> ITC.to_tuple(stamp)
      {{0, 1}, {0, 0, 2}}
      iex> ITC.from_tuple(:nope)
      {:error, :malformed}
  """
  @spec from_tuple(term) :: {:ok, t} | {:error, :malformed | :invalid_id | :invalid_event}
  def from_tuple({id, event}), do: new(id, event)
  def from_tuple(_), do: {:error, :malformed}

  @doc "Returns the stamp as an `{id, event}` tuple."
  @spec to_tuple(t) :: {Id.t(), Event.t()}
  def to_tuple(%__MODULE__{id: id, event: e}), do: {id, e}

  @doc """
  Splits a stamp into two with disjoint ids and the same history.

  Discard the input afterwards; keeping it alongside the children duplicates
  ownership.

      iex> {a, b} = ITC.fork(ITC.seed())
      iex> {ITC.to_tuple(a), ITC.to_tuple(b)}
      {{{1, 0}, 0}, {{0, 1}, 0}}
  """
  @spec fork(t) :: {t, t}
  def fork(%__MODULE__{id: id, event: e}) do
    {i1, i2} = Id.split(id)
    {%__MODULE__{id: i1, event: e}, %__MODULE__{id: i2, event: e}}
  end

  @doc """
  Records a local event.

  Raises `ArgumentError` for an anonymous stamp, which owns nothing to record
  into.

      iex> ITC.seed() |> ITC.event() |> ITC.event()
      #ITC<1 | 2>
  """
  @spec event(t) :: t
  def event(%__MODULE__{id: 0}) do
    raise ArgumentError, "cannot record an event on an anonymous stamp (id 0)"
  end

  def event(%__MODULE__{id: id, event: e} = stamp) do
    case Event.fill(id, e) do
      ^e ->
        {grown, _cost} = Event.grow(id, e)
        %{stamp | event: grown}

      filled ->
        %{stamp | event: filled}
    end
  end

  @doc """
  Merges two stamps: sums their ids and takes the pointwise maximum of their
  histories.

  Returns `{:error, :overlapping_ids}` if both stamps own part of the same
  region.
  """
  @spec join(t, t) :: {:ok, t} | {:error, :overlapping_ids}
  def join(%__MODULE__{id: i1, event: e1}, %__MODULE__{id: i2, event: e2}) do
    with {:ok, id} <- Id.sum(i1, i2) do
      {:ok, %__MODULE__{id: id, event: Event.join(e1, e2)}}
    end
  end

  @doc "Like `join/2`, but raises `ITC.OverlapError` on overlapping ids."
  @spec join!(t, t) :: t
  def join!(a, b) do
    case join(a, b) do
      {:ok, stamp} -> stamp
      {:error, :overlapping_ids} -> raise ITC.OverlapError, left: a, right: b
    end
  end

  @doc """
  Returns `{anonymous, stamp}`. The anonymous copy carries the history but no
  id, so it can travel on messages without transferring ownership.

  This follows the paper, which defines peek as returning both stamps.

      iex> {anon, _} = ITC.peek(ITC.event(ITC.seed()))
      iex> anon
      #ITC<0 | 1>
  """
  @spec peek(t) :: {t, t}
  def peek(%__MODULE__{event: e} = stamp), do: {%__MODULE__{id: 0, event: e}, stamp}

  @doc """
  Records a send event. Returns `{message_stamp, local_stamp}`; attach
  `message_stamp` to the outgoing message.
  """
  @spec send_event(t) :: {t, t}
  def send_event(stamp), do: stamp |> event() |> peek()

  @doc """
  Merges an incoming message stamp into `local`, then records the receive.

  `local` must own a non-zero id.
  """
  @spec receive_event(t, t) :: {:ok, t} | {:error, :overlapping_ids}
  def receive_event(local, message) do
    with {:ok, joined} <- join(local, message), do: {:ok, event(joined)}
  end

  @doc """
  Joins two stamps and forks the result. Both come back with the same
  history and with the combined id space split between them.
  """
  @spec sync(t, t) :: {:ok, {t, t}} | {:error, :overlapping_ids}
  def sync(a, b) do
    with {:ok, joined} <- join(a, b), do: {:ok, fork(joined)}
  end

  @doc "True when `a`'s history is contained in `b`'s."
  @spec leq?(t, t) :: boolean
  def leq?(%__MODULE__{event: a}, %__MODULE__{event: b}), do: Event.leq?(a, b)

  @doc """
  Compares two stamps' histories.

  This is a partial order, so it is deliberately not called `compare/2`:
  `Enum.sort/2` expects every pair to be ordered, and concurrent stamps are
  not.

    * `:eq` means the histories are identical (the ids may differ).
    * `:lt` / `:gt` mean one history strictly contains the other.
    * `:concurrent` means neither contains the other.
  """
  @spec relation(t, t) :: relation
  def relation(%__MODULE__{event: e}, %__MODULE__{event: e}), do: :eq

  def relation(%__MODULE__{event: a}, %__MODULE__{event: b}) do
    case {Event.leq?(a, b), Event.leq?(b, a)} do
      {true, true} -> :eq
      {true, false} -> :lt
      {false, true} -> :gt
      {false, false} -> :concurrent
    end
  end

  @doc "True when neither history contains the other."
  @spec concurrent?(t, t) :: boolean
  def concurrent?(a, b), do: relation(a, b) == :concurrent

  @doc "True when the stamp owns no part of the interval."
  @spec anonymous?(t) :: boolean
  def anonymous?(%__MODULE__{id: id}), do: id == 0

  @doc """
  True when `term` is a stamp whose trees are both well-formed and normalized.
  """
  @spec valid?(term) :: boolean
  def valid?(%__MODULE__{id: id, event: e}), do: Id.normal?(id) and Event.normal?(e)
  def valid?(_), do: false

  @doc """
  Total node count across both trees.

  Useful as a gauge: steady growth usually means id space is leaking from
  participants that crashed without joining back.
  """
  @spec node_count(t) :: pos_integer
  def node_count(%__MODULE__{id: id, event: e}), do: Id.node_count(id) + Event.node_count(e)

  # ---------------------------------------------------------------------------
  # External Term Format
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a stamp as External Term Format: `{#{@wire_version}, id, event}`.

  The encoding is canonical for a given Erlang/OTP major release. OTP does
  not promise identical bytes across major releases, so do not persist hashes
  of these bytes across upgrades; `encode_compact/2` has no such caveat.

      iex> ITC.seed() |> ITC.encode() |> ITC.decode()
      {:ok, ITC.seed()}
  """
  @spec encode(t) :: binary
  def encode(%__MODULE__{id: id, event: e}) do
    :erlang.term_to_binary({@wire_version, id, e}, [:deterministic])
  end

  @doc """
  Decodes and validates bytes produced by `encode/1`.

  Before parsing, the input must fit in `:max_bytes` and start with the
  uncompressed header `encode/1` writes. That rejects compressed terms,
  which would otherwise inflate up to roughly 8000x before validation. The
  term is parsed with `[:safe]`, so no atoms are created, and trailing bytes
  are rejected. Both trees must be normalized, the largest counter must not
  exceed `:max_counter`, and the input must be the canonical encoding of the
  result.

  ## Options

    * `:max_bytes` - largest accepted input. Defaults to #{@default_max_bytes}.
    * `:max_counter` - largest accepted event count, or `:infinity`.
      Defaults to 2^64 - 1. Bounds the damage a faulty or hostile peer can do
      by injecting huge integers that every later stamp would carry.
  """
  @spec decode(binary, [decode_opt]) :: {:ok, t} | {:error, decode_error}
  def decode(bin, opts \\ []) when is_binary(bin) and is_list(opts) do
    {max_bytes, max_counter} = decode_opts!(opts)

    with :ok <- check_size(byte_size(bin), max_bytes),
         :ok <- check_etf_header(bin),
         {:ok, {_version, id, e}} <- safe_binary_to_term(bin),
         {:ok, stamp} <- new(id, e),
         :ok <- check_counter(e, max_counter),
         :ok <- check_canonical(encode(stamp), bin) do
      {:ok, stamp}
    end
  end

  # <<131 (version), 104 (SMALL_TUPLE_EXT), 3 (arity), 97 (SMALL_INTEGER_EXT), version>>
  defp check_etf_header(<<131, 104, 3, 97, @wire_version, _::binary>>), do: :ok

  defp check_etf_header(<<131, 104, 3, 97, _other, _::binary>>),
    do: {:error, :unsupported_version}

  defp check_etf_header(_), do: {:error, :malformed}

  defp safe_binary_to_term(bin) do
    size = byte_size(bin)

    case :erlang.binary_to_term(bin, [:safe, :used]) do
      {{@wire_version, _, _} = term, ^size} -> {:ok, term}
      {_term, _used} -> {:error, :malformed}
    end
  rescue
    ArgumentError -> {:error, :malformed}
  end

  # ---------------------------------------------------------------------------
  # Appendix A compact encoding
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a stamp with the bit encoding from Appendix A of the paper.

  By default the bits are zero-padded to whole bytes so the result is a
  binary. With `pad: false` the result is the exact bitstring that
  `itc:encode/1` in the Erlang reference implementations produces, which is
  what `itc:decode/1` there expects.

      iex> ITC.encode_compact(ITC.seed())
      <<0b00110000>>
      iex> ITC.encode_compact(ITC.seed(), pad: false)
      <<0b001::size(3), 0b1000::size(4)>>
  """
  @spec encode_compact(t, pad: boolean) :: bitstring
  def encode_compact(%__MODULE__{id: id, event: e}, opts \\ []) do
    bits = Compact.encode(id, e)
    pad? = Keyword.validate!(opts, pad: true)[:pad]

    unless is_boolean(pad?) do
      raise ArgumentError, ":pad must be a boolean, got: #{inspect(pad?)}"
    end

    if pad? do
      pad = rem(8 - rem(bit_size(bits), 8), 8)
      <<bits::bitstring, 0::size(pad)>>
    else
      bits
    end
  end

  @doc """
  Decodes and validates bits produced by `encode_compact/2` or by
  `itc:encode/1` in the Erlang reference implementations.

  Accepts the exact bitstring, or the bitstring zero-padded to whole bytes.
  Any other trailing bits are rejected, as are non-canonical encodings and
  non-normalized trees. Counters are bounded while parsing, so input made of
  long integer prefixes is rejected in linear time. Takes the same options
  as `decode/2`; `:max_bytes` applies to the size rounded up to whole bytes.

      iex> ITC.seed() |> ITC.encode_compact() |> ITC.decode_compact()
      {:ok, ITC.seed()}
  """
  @spec decode_compact(bitstring, [decode_opt]) :: {:ok, t} | {:error, decode_error}
  def decode_compact(bits, opts \\ []) when is_bitstring(bits) and is_list(opts) do
    {max_bytes, max_counter} = decode_opts!(opts)

    with :ok <- check_size(byte_size(bits), max_bytes),
         {:ok, id, e, padding} <- Compact.decode(bits, max_counter),
         :ok <- check_padding(bits, padding),
         {:ok, stamp} <- new(id, e),
         :ok <- check_counter(e, max_counter),
         used = bit_size(bits) - bit_size(padding),
         <<canonical::bitstring-size(^used), _::bitstring>> = bits,
         :ok <- check_canonical(Compact.encode(id, e), canonical) do
      {:ok, stamp}
    end
  end

  # Two accepted forms: the exact bitstring (what itc:encode/1 produces), or a
  # binary whose final byte is completed with fewer than 8 zero bits. Partial
  # padding that leaves the input short of a byte boundary is rejected, so
  # every stamp has exactly one accepted binary encoding.
  defp check_padding(_bits, <<>>), do: :ok

  defp check_padding(bits, padding) when is_binary(bits) do
    size = bit_size(padding)
    if size < 8 and padding == <<0::size(size)>>, do: :ok, else: {:error, :malformed}
  end

  defp check_padding(_bits, _padding), do: {:error, :malformed}

  # ---------------------------------------------------------------------------
  # Shared decode helpers
  # ---------------------------------------------------------------------------

  defp decode_opts!(opts) do
    opts =
      Keyword.validate!(opts, max_bytes: @default_max_bytes, max_counter: @default_max_counter)

    max_bytes = opts[:max_bytes]
    max_counter = opts[:max_counter]

    unless is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError, ":max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
    end

    unless max_counter == :infinity or (is_integer(max_counter) and max_counter >= 0) do
      raise ArgumentError,
            ":max_counter must be a non-negative integer or :infinity, got: #{inspect(max_counter)}"
    end

    {max_bytes, max_counter}
  end

  defp check_size(size, max) when size <= max, do: :ok
  defp check_size(_size, _max), do: {:error, :too_large}

  defp check_counter(_e, :infinity), do: :ok

  defp check_counter(e, max) do
    if Event.max_of(e) <= max, do: :ok, else: {:error, :counter_too_large}
  end

  defp check_canonical(same, same), do: :ok
  defp check_canonical(_canonical, _given), do: {:error, :non_canonical}
end

defmodule ITC.OverlapError do
  @moduledoc "Raised by `ITC.join!/2` when both stamps own part of the same region."
  defexception [:left, :right]

  @impl true
  def message(%{left: left, right: right}) do
    "cannot join stamps with overlapping ids: #{inspect(left)} and #{inspect(right)}"
  end
end

defimpl Inspect, for: ITC do
  import Inspect.Algebra

  def inspect(stamp, opts) do
    {id, e} = ITC.to_tuple(stamp)
    concat(["#ITC<", to_doc(id, opts), " | ", to_doc(e, opts), ">"])
  end
end
