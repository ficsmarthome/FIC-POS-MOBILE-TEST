# FIC POS Mobile V1.13.13 — Recipe Offline View

- Dedicated native Recipe screen instead of generic JSON listing.
- Read-only in the mobile app for every role: no create/edit/delete/import actions are exposed.
- Search locally by recipe name, ingredients, quantity, method and notes.
- Filter by dynamic recipe groups.
- Shows ingredient/quantity pairs, method, notes and the exact glass photo/name assigned by the store.
- Recipe + glass data are cached per current branch in SQLite.
- Glass images are downloaded once, stored as base64 in the branch recipe cache and reused offline.
- Recipe cache is prefetched immediately after Home loads online, so staff can later open Recipes without Internet.
- Switching branches naturally uses a separate branch cache.
