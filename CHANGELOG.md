# Changelog

## 0.1.0

Initial release of Interval Tree Clocks for Elixir, following the OPODIS 2008
paper, with ownership operations, causal comparison, validating constructors,
ETF and Appendix A compact wire formats.

Before release:

* `receive_event/2` now requires an anonymous message and returns
  `{:error, :non_anonymous_message}` for owning messages. Anonymous local
  stamps raise `ArgumentError`.
* Finite counter validation now short-circuits when a cumulative counter
  exceeds its limit, avoiding expensive arithmetic before rejecting oversized
  ETF counters. Counter limits and wire formats are unchanged.
* Compact encoding rejects negative counters in hand-built invalid stamps
  instead of silently truncating them.
