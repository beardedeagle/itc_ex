# ITC

Interval Tree Clocks for Elixir, following Almeida, Baquero & Fonte,
*Interval Tree Clocks: A Logical Clock for Dynamic Systems*, OPODIS 2008
(LNCS 5401, [doi:10.1007/978-3-540-92221-6_18](https://doi.org/10.1007/978-3-540-92221-6_18),
[PDF](https://gsd.di.uminho.pt/members/cbm/ps/itc2008.pdf)).

ITC tracks causality the way version vectors do, but without globally unique
replica ids. Participants are created with `fork/1` and retired with
`join/2`, allowing trees to compact as ownership and history merge. Actual
size depends on allocation history, tree shape and counters as well as the
live participants; ordinary fork/join churn can grow trees with no lost ids.

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
Supported runtimes are Elixir 1.17 or later with OTP 27 or later.

## API

| Function | Purpose |
| --- | --- |
| `seed/0` | The root stamp. Create exactly one per system. |
| `fork/1` | Split a stamp into two with disjoint ids. Discard the parent. |
| `event/1` | Record a local event. Raises on anonymous stamps. |
| `join/2`, `join!/2` | Merge ids and histories. Returns `{:error, :overlapping_ids}` (or raises) when both stamps own the same region. |
| `peek/1` | Make an id-less copy for attaching to messages. |
| `send_event/1`, `receive_event/2`, `sync/2` | Composite operations; receive requires an anonymous message. |
| `leq?/2`, `relation/2`, `concurrent?/2` | Causal comparison. `relation/2` returns `:eq`, `:lt`, `:gt` or `:concurrent`. |
| `encode/1`, `decode/2` | External Term Format wire format. |
| `encode_compact/2`, `decode_compact/2` | The paper's Appendix A bit encoding. |
| `new/2`, `from_tuple/1`, `to_tuple/1` | Validating constructors and `{id, event}` conversion. |
| `anonymous?/1` | Check whether a stamp owns no id space. |
| `valid?/1`, `node_count/1` | Validation and a diagnostic gauge of tree size. |

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
* Never recover to a stamp older than an externally visible event,
  acknowledgement or ownership transfer. Durably couple these effects with
  their stamp updates, or recover state that includes them before reusing
  ownership.
* Reclaim a crashed participant's id by joining its last durable stamp, but
  only if that stamp includes all externally visible changes, after a
  consensus decision that it is dead, and with the old holder fenced.
  Fencing alone neither repairs stale history nor revokes ids already
  delegated to live participants.

For example, sending an event and then recovering the sender's earlier
checkpoint lets a different event reuse that timestamp. A receiver of the
first event then appears to have seen the second. The library cannot detect
this rollback; persisting an old parent across a published fork similarly
duplicates ownership.

On successful `join/2` or `join!/2`, discard the owning inputs and use the
merged stamp. On successful `sync/2`, replace the owning inputs with the two
returned stamps. Anonymous message snapshots may be retained and redelivered.
Create them with `peek/1` or `send_event/1`: `receive_event/2` rejects owning
messages with `{:error, :non_anonymous_message}` and preserves the receiver's
id. Both send and receive raise `ArgumentError` on an anonymous local stamp.

`join/2` detects overlap instead of silently taking the union. In a correct
system, overlap means one of the rules above was broken; the usual cause is a
zombie still holding an id that was reclaimed.

## Wire formats

| | `encode/1` | `encode_compact/2` |
| --- | --- | --- |
| Format | `{1, id, event}` as External Term Format | Appendix A bits, zero-padded to whole bytes |
| Size | Depends on trees and counters | Depends on trees and counters; often smaller |
| Stable across OTP releases | Test canonical bytes across supported runtimes | Independent of OTP's ETF encoder |
| Interoperable with | BEAM nodes running this library | The Erlang reference implementation (`itc:encode/1`, `itc:decode/1`) |

`encode_compact(stamp, pad: false)` returns the exact bitstring that the
reference `itc:encode/1` produces, which is what its `itc:decode/1` expects.
`decode_compact/2` accepts either form.

ETF canonicality uses the receiving runtime's encoder. Test supported OTP
versions before rolling upgrades: differing encodings can be rejected as
`:non_canonical`. Encoding success does not guarantee acceptance under the
decoder's configured byte and counter limits.

Both decoders treat input as untrusted. `decode/2` requires a binary and
`decode_compact/2` a bitstring (including binaries); other types are programmer
errors. Check the type first if the source does not guarantee it.

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

Encoded size limits do not bound expanded heap or stack use. A 64 KiB compact
input with a deeply nested id used roughly 8 MB of process memory immediately
after decoding in one local probe; this is not a peak-memory bound. Choose
`:max_bytes` together with decode concurrency.
Avoid logging whole untrusted stamps when accepting unbounded counters;
their textual representation can be much larger than the input.

Both encoders run in time linear in input size; decoders do so with bounded
counters. Finite counter validation stops at the first cumulative value
above the limit, so an oversized ETF integer is rejected without propagating
it through every ancestor. Very large finite limits can still make arithmetic
on cumulative offsets cost tree depth times integer width.
`max_counter: :infinity` skips that check. Run
`mix run bench/size_and_decode.exs` for two-participant churn, accepted compact
inputs with large finite limits, and rejected oversized ETF counters.

ITC has no defence against a peer that lies about its history or ownership.
Authenticate stamps at the transport layer; applications still own peer
authorization, durable state transitions and fencing.

## Testing

```sh
mix test --warnings-as-errors  # unit tests, doctests and StreamData properties
mix dialyzer
mix hex.audit
mix deps.unlock --check-unused
mix format --check-formatted
mix compile --force --warnings-as-errors
mix docs --warnings-as-errors
mix hex.build
mix run --no-start scripts/check_package.exs
npx --yes markdownlint-cli2@0.23.3 README.md CHANGELOG.md
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
* **Causality.** Random fork, event, join, sync and asynchronous message
  traffic runs alongside a ground-truth set of event ids per replica.
  After every step:
  * `leq?/2` agrees with set inclusion for live replicas and retained messages,
    including delayed, repeated and reordered delivery after sender retirement;
  * the live ids partition [0, 1) exactly;
  * every stamp is normalized, matches the spec, and survives both wire
    formats.
* **Semantics.** Ids are expanded to explicit cell sets and event trees to
  explicit per-cell values. Normalization must preserve membership and cell
  values on raw trees and yield normal form. `split` and `sum` must match set operations,
  `Event.join` the pointwise max, and `leq?` the pointwise `<=`. `event/1`
  must raise at least one owned cell and leave every unowned cell unchanged.
* **Hostile input.** Compressed ETF, non-canonical encodings, oversized
  counters, long integer prefixes, truncation, bad padding and arbitrary bit
  strings and ETF bodies.

The development toolchain is pinned in `.tool-versions`. CI is configured to
check Elixir 1.17 with OTP 27 and the pinned current runtime, including package
contents and compilation of the extracted package without development
dependencies.
Before publishing, tag the reviewed release commit `v0.1.0` so the generated
documentation's source links refer to that release.

## License

Copyright 2026 beardedeagle. Licensed under
[Apache-2.0](https://github.com/beardedeagle/itc_ex/blob/v0.1.0/LICENSE).
