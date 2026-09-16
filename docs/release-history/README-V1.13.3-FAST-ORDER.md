# FIC POS Mobile V1.13.3+58 — FAST ORDER

Based directly on V1.13.2+57. Keeps all previous offline, table-total and payment-navigation fixes.

## Performance changes
- Add item is optimistic and no longer globally locks the order screen.
- Add-item API response is applied directly; no full `load()` after every tap.
- Rapid taps are allowed while previous add requests are still in flight.
- Quantity +/- is optimistic and debounced 250 ms per detail row.
- Quantity response is applied directly; no full order reload on success.
- Order sync polling pauses while fast mutations/debounce are pending to avoid racing the user's own changes.
- Network failure still falls back to existing offline queue behavior.
- Non-network quantity failure reloads the order to reconcile safely.

## Version
`1.13.3+58`
