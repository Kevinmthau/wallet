# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Deploy Commands

This project uses xcodegen for project generation:

```bash
# Regenerate Xcode project after modifying project.yml or adding/removing files
xcodegen generate

# Build for iOS device
xcodebuild -project Wallet.xcodeproj -scheme Wallet -destination "generic/platform=iOS" -allowProvisioningUpdates build

# Install to connected iPhone (get device ID from: xcrun devicectl list devices)
xcrun devicectl device install app --device "<DEVICE_ID>" "/Users/kevinthau/Library/Developer/Xcode/DerivedData/Wallet-bubmpkhzrhglkudrthpptqimyzlt/Build/Products/Debug-iphoneos/Wallet.app"

# Build for simulator
xcodebuild -project Wallet.xcodeproj -scheme Wallet -destination "platform=iOS Simulator,name=iPhone 16 Pro" build

# Run unit tests from command line
./scripts/test.sh

# Equivalent via Make
make test

# Optional: pin a destination manually if needed
DESTINATION="platform=iOS Simulator,name=iPhone 16 Pro,OS=latest" ./scripts/test.sh
```

## Architecture Overview

iOS card wallet app using SwiftUI + Core Data with CloudKit sync. Stores photos of membership cards, IDs, and insurance cards.

### Data Layer
- **Core Data model defined programmatically** in `Persistence.swift` (no .xcdatamodeld file)
- Uses `NSPersistentCloudKitContainer` for automatic iCloud sync
- CloudKit requires all attributes to have default values or be optional
- `Card` entity stores front/back images as binary data with external storage enabled
- `CardStore` is the main view model using `@Observable` macro with generic `fetch()` helper for queries

### Views Flow
1. `CardListView` - Apple Wallet-style stacked card UI with custom header and context menu actions
2. `FullScreenCardView` - Full-screen card display (tap to flip, swipe down to dismiss)
3. `CardFormView` - Unified add/edit form using `CardFormMode` enum (`.add` or `.edit(Card)`)
4. `CardDetailView` - Card detail view with zoom/pan gestures

### Reusable Components (`Views/Components/`)
- `WalletCardView` - Card display with image, gradient overlay, and metadata
- `FlippableCardView` - Front/back flip animation
- `CardImagePickerButton` - Image picker with scan/enhance/remove actions

### Scanner System
Split into focused components for maintainability:
- `AutoCaptureScanner` - Main scanner view, orchestration, and image processing
- `CameraManager` (`Utilities/`) - AVFoundation camera hardware and `VNDetectRectanglesRequest`
- `CameraPreviewView` - UIViewRepresentable camera preview
- `ScannerOverlay` - `CardOverlay` and `CardCorners` visual feedback

Scanner features:
- Auto-captures after card is stable for ~1 second
- Perspective correction via `CIFilter.perspectiveCorrection()`
- Text-based orientation detection using `VNRecognizeTextRequest`
- Manual capture fallback button

### Image Enhancement (`ImageEnhancer.swift`)
Core Image filters for card legibility: auto-adjust, sharpen, noise reduction, unsharp mask.

### OCR (`OCRExtractor.swift`)
Vision framework text extraction using `VNRecognizeTextRequest`. Singleton with async `extractText(from:)` method returning `OCRExtractionResult`.

### Logging (`AppLogger.swift`)
Uses `os.Logger` with categories: `UI`, `Data`, `Scanner`. Filter in Xcode console with `subsystem:com.kevinthau.wallet`.

## Key Technical Notes

- Development Team ID: `3JXY2MS2Y3`
- Bundle ID: `com.kevinthau.wallet`
- iOS 17.0+ target, Swift 5.9
- Portrait-only orientation, requires full screen
- Entitlements: iCloud (CloudKit) and key-value store
- Layout constants defined in `Constants.swift`
