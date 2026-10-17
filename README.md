# ITC

Interval Tree Clocks for Elixir, following Almeida, Baquero & Fonte,
*Interval Tree Clocks: A Logical Clock for Dynamic Systems*, OPODIS 2008
(LNCS 5401, [doi:10.1007/978-3-540-92221-6_18](https://doi.org/10.1007/978-3-540-92221-6_18),
[PDF](https://gsd.di.uminho.pt/members/cbm/ps/itc2008.pdf)).

ITC tracks causality the way version vectors do, but without globally unique
replica ids. Participants are created with `fork/1` and retired with
`join/2`, so a stamp's size follows the set of participants that are live
now, not every participant that has ever existed.

```elixir
{a, b} = ITC.fork(ITC.seed())

{msg, a} = ITC.send_event(a)          # record a send, get an id-less copy to ship
{:ok, b} = ITC.receive_event(b, msg)  # merge it and record the receive

ITC.relation(a, b)                    #=> :lt
ITC.join(a, b)                        #=> {:ok, #ITC<1 | 1>}
```

## Installation

```elixir
def deps do
  [{:itc_ex, "~> 0.1"}]
end
```

The OTP application is `:itc_ex` and the module is `ITC`. Existing Erlang ITC
packages on Hex register an application named `:itc`, so that name is avoided.

## API

| Function | Purpose |
| --- | --- |
| `seed/0` | The root stamp. Create exactly one per system. |
| `fork/1` | Split a stamp into two with disjoint ids. Discard the parent. |
| `event/1` | Record a local event. Raises on anonymous stamps. |
| `join/2`, `join!/2` | Merge ids and histories. Returns `{:error, :overlapping_ids}` (or raises) when both stamps own the same region. |
| `peek/1` | Make an id-less copy for attaching to messages. |
| `send_event/1`, `receive_event/2`, `sync/2` | The paper's composite operations. |
| `leq?/2`, `relation/2`, `concurrent?/2` | Causal comparison. `relation/2` returns `:eq`, `:lt`, `:gt` or `:concurrent`. |
| `encode/1`, `decode/2` | External Term Format wire format. |
| `encode_compact/2`, `decode_compact/2` | The paper's Appendix A bit encoding, about 5x smaller. |
| `new/2`, `from_tuple/1`, `to_tuple/1` | Validating constructors and `{id, event}` conversion. |
| `valid?/1`, `node_count/1` | Validation, and a size gauge for spotting leaked id space. |

`ITC.Id` and `ITC.Event` expose the tree operations from the paper (`split`,
`sum`, `norm`, `fill`, `grow`, `join`, `leq?`) for anyone building on them.

## Stamps are opaque

Obtain stamps only from the operations above or from the validating
constructors (`new/2`, `from_tuple/1`, `decode/2`, `decode_compact/2`).
Every algorithm relies on the paper's normal form; a hand-built `%ITC{}` with
a non-normalized tree makes `event/1` silently record nothing and makes
comparisons wrong. Use `valid?/1` on anything you did not get from this
library.

## Ownership rules

The id is a capability. If it is ever duplicated, two holders record events
into the same region, their histories become indistinguishable, and
comparisons start returning wrong answers without any error.

* Derive every stamp from a single `seed/0`.
* After `fork/1`, keep only the two children.
* A restarted participant resumes from its last durable stamp, or gets a new
  fork from a live holder. It never seeds again.
* Reclaim a crashed participant's id by joining its last durable stamp, but
  only after a consensus decision that it is dead, and with the old holder
  fenced.

`join/2` detects overlap instead of silently taking the union. In a correct
system, overlap means one of the rules above was broken; the usual cause is a
zombie still holding an id that was reclaimed.

## Wire formats

| | `encode/1` | `encode_compact/2` |
| --- | --- | --- |
| Format | `{1, id, event}` as External Term Format | Appendix A bits, zero-padded to whole bytes |
| Size (64 replicas) | ~400 B | ~75 B |
| Stable across OTP releases | Within a major release only | Yes |
| Interoperable with | BEAM nodes running this library | The Erlang reference implementation (`itc:encode/1`, `itc:decode/1`) |

`encode_compact(stamp, pad: false)` returns the exact bitstring that the
reference `itc:encode/1` produces, which is what its `itc:decode/1` expects.
`decode_compact/2` accepts either form.

Both decoders treat input as untrusted:

1. Reject input larger than `:max_bytes` (default 64 KiB) before parsing.
2. ETF only: require the uncompressed header `encode/1` writes. Compressed
   terms would otherwise inflate up to roughly 8000x before validation.
   Parse with `[:safe]`, so no atoms are created, and reject trailing bytes.
3. Compact only: count integer prefixes before building any number, so a
   long run of prefix bits costs linear time, and accept either the exact
   bitstring or the binary zero-padded to the next byte boundary, nothing in
   between.
4. Require both trees to be normalized.
5. Reject any counter above `:max_counter` (default 2^64 - 1). A peer that
   injects huge integers would otherwise make every later stamp carry them.
6. Require the input to be the canonical encoding of the result, so for any
   accepted binary, byte equality is stamp equality.

Both encoders and both decoders run in time linear in the size of their
input, including stamps with very large counters.

ITC has no defence against a peer that lies about its history. If peers are
not trusted, authenticate stamps at the transport layer.

## Testing

```sh
mix test      # unit tests, doctests and StreamData properties
mix dialyzer
```

The suite checks the implementation against independent oracles and against
the paper itself:

* **The paper as code.** `test/support/itc_spec.ex` transcribes the paper's
  definitions literally, using the general recursive `min`, allocating
  `lift`s, and the lexicographic cost the paper says its constant N stands in
  for. `event`, `join`, `fork`, `peek`, `leq` and the Appendix A encoder must
  agree with it exactly on arbitrary normalized inputs.
* **The paper's example.** Every intermediate stamp of the run in section
  5.1, derived by hand.
* **Causality.** Random fork, event, join and message traffic runs alongside
  a ground-truth set of event ids per replica. After every step:
  * `leq?/2` agrees with set inclusion for every pair of replicas;
  * the live ids partition [0, 1) exactly;
  * every stamp is normalized, matches the spec, and survives both wire
    formats.
* **Semantics.** Ids are expanded to explicit cell sets and event trees to
  explicit per-cell values. `split` and `sum` must match set operations,
  `Event.join` the pointwise max, and `leq?` the pointwise `<=`. `event/1`
  must raise at least one owned cell and leave every unowned cell unchanged.
* **Hostile input.** Compressed ETF, non-canonical encodings, oversized
  counters, long integer prefixes, truncation, bad padding and arbitrary bit
  strings.
