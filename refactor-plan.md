# Production Hardening Refactor Plan

This file tracks high-value refactor and hardening work for the Wallet app. It is intentionally focused on correctness, stale UI, race conditions, memory/performance, and architectural fragility rather than cosmetic cleanup.

## Status Legend

- `Not Started`: accepted backlog item with no active work.
- `In Progress`: currently being implemented.
- `Blocked`: cannot move forward without another fix, decision, or environment issue.
- `Done`: implemented and verified against the acceptance criteria.
- `Deferred`: intentionally postponed.

## Progress Board

| ID | Priority | Status | Owner | Area | Summary |
| --- | --- | --- | --- | --- | --- |
| HD-001 | P0 | Done | Codex | CloudKit/Core Data | Prevent access tracking from winning edit conflicts |
| HD-002 | P0 | Done | Codex | CloudKit/Core Data | Replace whole-object timestamp conflict resolution |
| HD-003 | P0 | Done | Codex | Card mutations | Avoid partial inserted cards when image processing fails |
| HD-004 | P1 | Done | Codex | Images/List UI | Reduce list decode pressure and main-actor binary reads |
| HD-005 | P1 | Not Started | Unassigned | Images/Memory | Stop holding full-resolution images longer than needed |
| HD-006 | P1 | Not Started | Unassigned | Images/OCR | Make image and OCR work bounded and cancellable |
| HD-007 | P2 | Not Started | Unassigned | Core Data/UI actions | Use object IDs for delayed and async card actions |
| HD-008 | P2 | Not Started | Unassigned | Search | Debounce search and reduce expensive note predicates |
| HD-009 | P2 | Not Started | Unassigned | Persistence | Surface persistent store load failures |
| HD-010 | P3 | Not Started | Unassigned | Tests/CI | Stabilize simulator test verification |

## P0: Correctness and Data Safety

### HD-001: Prevent Access Tracking From Winning Edit Conflicts

- Status: `Done`
- Owner: Codex
- Target files: `Wallet/Models/Card.swift`, `Wallet/ViewModels/CardStore.swift`, `Wallet/Models/Persistence.swift`, `WalletTests/CardStoreTests.swift`
- Problem: viewing a card updates `lastAccessedAt` and also updates `updatedAt`; the merge policy uses `updatedAt` to decide the winning object, so a stale device that only opens a card can overwrite a real edit from another device.
- Intended fix: separate access recency from edit recency. `markAccessed` should update only access-specific state and must not advance the edit/conflict timestamp.
- Acceptance criteria:
  - Opening or viewing a card does not mutate `updatedAt`.
  - Sorting by recently used still updates after `markAccessed`.
  - Existing add/edit/favorite/delete mutations still update the edit timestamp.
  - Unit tests cover access updates separately from edit updates.
- Notes:
  - 2026-05-05: Started implementation to separate access recency from edit timestamps.
  - 2026-05-05: Implemented and verified with `./scripts/test.sh` on iOS Simulator `id=9AA5D33C-B1CA-46A6-A1FC-C0E1EE7F7B63`; 18 tests passed.
  - Current risk points: `Card.updateLastAccessed`, `CardStore.markAccessed`, and `CardTimestampMergePolicy`.

### HD-002: Replace Whole-Object Timestamp Conflict Resolution

- Status: `Done`
- Owner: Codex
- Target files: `Wallet/Models/Persistence.swift`, `WalletTests/CardStoreTests.swift`
- Problem: `CardTimestampMergePolicy` resolves an entire object as object-trump or store-trump. Non-overlapping edits, such as notes changed on one device and favorite toggled on another, can be lost.
- Intended fix: replace whole-object winner selection with field-aware conflict handling for independent fields, while preserving deterministic behavior for truly conflicting writes to the same field.
- Acceptance criteria:
  - Non-overlapping concurrent edits are preserved.
  - Same-field conflicts resolve deterministically and are covered by tests.
  - Image data conflicts do not accidentally combine front/back changes incorrectly.
  - Merge behavior remains compatible with existing persisted stores.
- Notes:
  - This may require a small mutation metadata strategy if per-field timestamps are needed.
  - 2026-05-05: Implemented field-aware merge resolution using cached/store/local snapshots. Independent field edits are preserved, same-field conflicts still use deterministic `updatedAt` ordering, access recency keeps the latest timestamp, and same-side image conflicts keep the image pair from the winning edit.
  - 2026-05-05: Verified with `DESTINATION='id=F3F6E978-7C73-4E1A-80B6-1C9F068EA4FF' ./scripts/test.sh` on iPhone 17 Pro Max simulator; 22 tests passed.

### HD-003: Avoid Partial Inserted Cards on Image Processing Failure

- Status: `Done`
- Owner: Codex
- Target files: `Wallet/ViewModels/CardStore.swift`, `WalletTests/CardStoreTests.swift`
- Problem: `addCard` inserts a `Card` before awaiting image compression. If compression throws, the catch path returns `false` without rolling back or deleting the inserted object.
- Intended fix: prepare image data before inserting the Core Data object, or explicitly roll back/delete the inserted card on failure.
- Acceptance criteria:
  - Failed image preparation leaves no inserted or unsaved partial card in the context.
  - `lastError` is populated with the underlying failure.
  - Successful add behavior remains unchanged.
  - Unit tests cover failed front-image processing.
- Notes:
  - Prefer computing storage data first because it keeps Core Data mutation windows smaller.
  - 2026-05-05: Implemented by preparing front/back storage image data before inserting the Core Data object. Verified with `DESTINATION='id=F3F6E978-7C73-4E1A-80B6-1C9F068EA4FF' ./scripts/test.sh`; 26 tests passed.

## P1: Image Performance and Memory

### HD-004: Reduce List Decode Pressure and Main-Actor Binary Reads

- Status: `Done`
- Owner: Codex
- Target files: `Wallet/Views/CardListView.swift`, `Wallet/Views/Components/WalletCardView.swift`, `Wallet/Utilities/CardImageRepository.swift`
- Problem: the card list materializes all fetched cards, renders all card views in a `ZStack`, and each row reads binary image data from Core Data on the main actor before background decoding.
- Intended fix: load images by `NSManagedObjectID` on a background context and introduce a persistent or cached thumbnail path so the list does not read/decode full image blobs for every visible card.
- Acceptance criteria:
  - Thumbnail loading does not access `frontImageData` on the main actor.
  - List rendering starts image work only for cards that need display.
  - Scrolling/opening the list avoids full-size image decode.
  - Tests or instrumentation verify thumbnail cache invalidation when image data changes.
- Notes:
  - Consider persisted thumbnail data if CloudKit/storage behavior is acceptable; otherwise use background downsample plus bounded in-memory cache.
  - 2026-05-05: Started remaining HD-004 work. Existing thumbnail/display/full variants and downsampling are already present; current focus is objectID-based background-context thumbnail reads and gating image work for compressed stack rows.
  - 2026-05-05: Implemented objectID-based thumbnail reads on a private Core Data context, added `hasBackImage` metadata so list rows do not touch back-image blobs for the dual-sided indicator/filter, and gated thumbnail loading for compressed stack rows. Verified with `./scripts/test.sh` on iOS Simulator `id=9AA5D33C-B1CA-46A6-A1FC-C0E1EE7F7B63`; 29 tests passed.

### HD-005: Stop Holding Full-Resolution Images Longer Than Needed

- Status: `Not Started`
- Owner: Unassigned
- Target files: `Wallet/Views/CardFormView.swift`, `Wallet/Views/FullScreenCardView.swift`, `Wallet/Utilities/CardImageRepository.swift`
- Problem: edit mode loads `.full` images into observable state, sharing stores full images in `shareItems`, and `.full` uses `UIImage(data:)` without downsampling.
- Intended fix: use display-sized images for UI state, reserve full-resolution decode for share/export only, and clear full-resolution share state after the sheet is dismissed.
- Acceptance criteria:
  - Edit form previews use display-sized images.
  - Full-resolution images are not retained after share sheet dismissal.
  - Full-screen viewing uses display-sized images unless explicitly exporting.
  - Memory usage is materially lower when opening edit/full-screen/share flows with two-sided cards.
- Notes:
  - Preserve saved image quality; this is about display memory, not storage quality.

### HD-006: Make Image and OCR Work Bounded and Cancellable

- Status: `Not Started`
- Owner: Unassigned
- Target files: `Wallet/ViewModels/CardImageState.swift`, `Wallet/Utilities/ImageEnhancer.swift`, `Wallet/Utilities/OCRExtractor.swift`, `Wallet/Utilities/CardImageProcessor.swift`
- Problem: Swift tasks are cancelled, but underlying `DispatchQueue` and global queue work continues. A single `currentTask` also means front and back image operations can cancel each other.
- Intended fix: centralize image/OCR work behind bounded async executors or actors, and track front/back operations independently.
- Acceptance criteria:
  - Cancelling an image operation prevents stale state writes and limits additional work.
  - Front and back image operations do not cancel each other unless explicitly requested.
  - Concurrent image/OCR work is bounded to avoid CPU and memory spikes.
  - Tests cover stale result suppression for rapid image replacement.
- Notes:
  - Vision requests may not be fully cancellable, so stale-result suppression and concurrency limits are required even if hard cancellation is partial.

## P2: UI State, Async Actions, and Error Handling

### HD-007: Use Object IDs for Delayed and Async Card Actions

- Status: `Not Started`
- Owner: Unassigned
- Target files: `Wallet/ViewModels/CardStore.swift`, `Wallet/Views/CardListView.swift`, `Wallet/Views/FullScreenCardView.swift`
- Problem: delayed delete/share/edit flows capture live `Card` managed objects. CloudKit merges, deletes, or invalidates can make those references stale or unsafe.
- Intended fix: expose store APIs that accept `NSManagedObjectID` for delayed or async work and resolve objects inside the current context immediately before mutation/read.
- Acceptance criteria:
  - Delayed delete resolves the object ID immediately before deleting.
  - Share/export resolves image data from object ID rather than retaining a live object.
  - Missing/deleted objects fail gracefully.
  - Tests cover deleting an object that is already gone by the time the delayed action runs.
- Notes:
  - UI can still pass `Card` to purely synchronous display views where no delay/async boundary exists.

### HD-008: Debounce Search and Reduce Expensive Note Predicates

- Status: `Not Started`
- Owner: Unassigned
- Target files: `Wallet/Views/CardListView.swift`, `Wallet/Models/Persistence.swift`
- Problem: search refetches on every keystroke using `CONTAINS[cd]` against both name and notes. OCR-heavy notes can make this expensive.
- Intended fix: debounce search input before updating the fetch predicate and consider a normalized searchable field if profiling shows note search remains expensive.
- Acceptance criteria:
  - Typing in search does not refetch for every keystroke.
  - Clearing search updates immediately or after a short, predictable debounce.
  - Existing filter/sort behavior remains unchanged.
  - Tests cover predicate generation for search/filter combinations.
- Notes:
  - Start with debounce only; add schema/search-index changes only if needed.

### HD-009: Surface Persistent Store Load Failures

- Status: `Not Started`
- Owner: Unassigned
- Target files: `Wallet/Models/Persistence.swift`, `Wallet/WalletApp.swift`
- Problem: persistent store load failures are only logged. The app continues with no visible recovery state.
- Intended fix: expose store-load state from persistence setup and show a clear app-level error/recovery UI when the store cannot load.
- Acceptance criteria:
  - Store load failure is observable by the app root.
  - The app does not silently present an empty/broken wallet when persistence fails.
  - User-facing copy gives a practical next step without exposing internal error noise.
  - Tests cover failure-state propagation where feasible.
- Notes:
  - Avoid destructive recovery actions until there is an export/backup story.

## P3: Verification and Tooling

### HD-010: Stabilize Simulator Test Verification

- Status: `Not Started`
- Owner: Unassigned
- Target files: `scripts/test.sh`, `CLAUDE.md`
- Problem: the last audit build compiled, but tests did not launch because CoreSimulator failed with Mach error `-308`, then CoreSimulatorService became unavailable on retry.
- Intended fix: document the failure mode and harden the test script so it can recover or provide a precise operator action when simulator services are unavailable.
- Acceptance criteria:
  - `scripts/test.sh` gives a clear failure message when CoreSimulator is unavailable.
  - The script keeps the existing destination override behavior.
  - Documentation includes the known failure and recommended retry/reset steps.
  - A clean simulator environment can run the unit tests.
- Notes:
  - This is an environment/tooling hardening item, not an app behavior defect by itself.

## Update Protocol

- Update the status board whenever work starts or lands.
- Add a dated note under the item when status changes.
- Keep acceptance criteria current if implementation reveals a better target.
- Do not mark `Done` until tests or an explicit verification note is recorded.
