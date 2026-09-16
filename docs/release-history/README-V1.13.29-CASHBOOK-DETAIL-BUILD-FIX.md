# FIC POS Mobile V1.13.29+83

Build fix for Cashbook detail introduced in V1.13.28.

- Rewrote `CashbookPage.build()` with balanced widget parentheses.
- Preserved cashbook lazy-load (20/page), pull-to-refresh, create thu/chi and detail navigation.
- Restored loading-more spinner at the end of the list.
- No API or database change.
