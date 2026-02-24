# Phase 5: Polish & Performance

## Goal

完善錯誤處理、效能驗證、邊界情況處理。確認所有 FR 需求都已滿足。

## Prerequisites

- [ ] Phase 4 completed — All features implemented

## Tasks

### 5.1 Error Handling

- [ ] Missing file: if image URL no longer exists → show placeholder or skip
- [ ] Unsupported format: if CGImageSource fails → show placeholder
- [ ] Empty folder: if no images in folder → show message in window
- [ ] Single image: if only 1 image → next/previous do nothing gracefully
- [ ] Placeholder design: simple centered text "Cannot display image" or system icon

### 5.2 Performance Testing

- [ ] Test with 1000+ images folder:
  - Folder scan time < 500ms (FR non-functional requirement)
  - Memory usage < 500MB during browsing
  - Image switch < 100ms perceived latency
- [ ] Profile with Instruments (if needed):
  - Memory leaks check
  - Excessive allocations during rapid navigation
- [ ] Verify cache works: only ~5 images in memory at any time

### 5.3 Edge Cases

- [ ] Very large images (e.g., 10000x10000 panoramas): should display without crash
- [ ] Very small images (e.g., 1x1 favicon): should display centered
- [ ] Mixed formats in one folder (JPEG + PNG + HEIC + WebP): all display correctly
- [ ] Folder with non-image files mixed in: correctly filtered out
- [ ] Unicode/CJK filenames: sort and display correctly
- [ ] Filenames with special characters: spaces, parentheses, etc.
- [ ] Read-only folder: app can still browse
- [ ] Image deleted while viewing: graceful handling

### 5.4 FR Requirements Checklist

- [ ] **FR-001**: App in Open With menu (not default) — `LSHandlerRank: Alternate`
- [ ] **FR-002**: Scan folder, skip hidden files, natural sort
- [ ] **FR-003**: Lazy Loading ±2 images
- [ ] **FR-004**: Pinch Zoom 10%~1000%
- [ ] **FR-005**: Keyboard zoom Cmd+=/-/0/1
- [ ] **FR-006**: Zoom persistence (manual vs fit mode)
- [ ] **FR-007**: Scrollable when zoomed
- [ ] **FR-008**: Scroll to bottom → next image
- [ ] **FR-009**: Scroll to top → previous image
- [ ] **FR-010**: Next image → scroll to top
- [ ] **FR-011**: Previous image → scroll to bottom
- [ ] **FR-012**: Navigation shortcuts (→←, PageUp/Down, Home/End, Space)
- [ ] **FR-013**: Zoom shortcuts (same as FR-005)
- [ ] **FR-014**: Fullscreen toggle Cmd+F
- [ ] **FR-015**: Fit on Screen (default mode)
- [ ] **FR-016**: Always Fit on Open toggle (Cmd+*)
- [ ] **FR-017**: Fitting Options submenu (4 toggles)
- [ ] **FR-018**: Scaling Quality submenu (Low/Medium/High + Show Pixels)
- [ ] **FR-019**: Fullscreen hides title bar and Dock
- [ ] **FR-020**: Fullscreen retains all operations
- [ ] **FR-021**: Esc exits fullscreen
- [ ] **FR-022**: Window title "filename (index/total)"
- [ ] **FR-023**: Resize Window Automatically
- [ ] **FR-024**: Float on Top
- [ ] **FR-025**: Window size memory

### 5.5 Code Cleanup

- [ ] Remove any debug `print` statements
- [ ] Ensure consistent code style
- [ ] Add essential code comments for complex logic
- [ ] Verify no compiler warnings

## Verification

### Final Acceptance Test
1. Build clean: `xcodebuild clean build`
2. Launch app from Finder (double-click Cee.app in build output)
3. Right-click any JPEG → Open With → Cee → image displays in < 1 second
4. Pinch zoom in/out → smooth, cursor-centered
5. Scroll to bottom → auto page turn → view starts at top
6. `→` `→` `→` rapid navigation → correct images, no flicker
7. `Cmd+0` → fit on screen → `Cmd+1` → actual size
8. View menu → all items functional with correct checkmarks
9. `Cmd+F` → fullscreen → all operations work → `Esc` exit
10. Float on Top → window stays above all other apps
11. Quit → relaunch → all settings preserved
12. Open folder with 1000 images → scan instant, browsing smooth

## Files Modified

| File | Change |
|------|--------|
| `Cee/Services/ImageLoader.swift` | Error handling for decode failure, return placeholder |
| `Cee/Models/ImageFolder.swift` | Handle empty folder, single image edge cases |
| `Cee/Controllers/ImageViewController.swift` | Empty folder message, missing file graceful skip |
| `Cee/Controllers/ImageWindowController.swift` | Error state UI (placeholder view) |
| `Cee/Views/ImageContentView.swift` | Placeholder rendering for failed images |

## Notes

- **Performance profiling**: If scan time > 500ms, consider `DispatchQueue.global().async` for folder scanning (but ImageFolder.init is already fast for most cases since `contentsOfDirectory` is synchronous).
- **Memory**: If memory exceeds target, reduce `cacheRadius` from 2 to 1, or implement downsampled thumbnails for cache.
- **Open Questions from PRD**:
  - GIF: MVP shows first frame only (no animation)
  - Remember last position: out of scope for MVP
  - Scroll threshold: the `wasAtBottom + intentDown` pattern works well; adjust `edgeThreshold` if needed
