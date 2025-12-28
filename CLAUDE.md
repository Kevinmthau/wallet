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
```

## Architecture Overview

iOS card wallet app using SwiftUI + Core Data with CloudKit sync. Stores photos of membership cards, IDs, and insurance cards.

### Data Layer
- **Core Data model defined programmatically** in `Persistence.swift` (no .xcdatamodeld file)
- Uses `NSPersistentCloudKitContainer` for automatic iCloud sync
- CloudKit requires all attributes to have default values or be optional
- `Card` entity stores front/back images as binary data with external storage enabled
- `CardStore` is the main view model using `@Observable` macro for CRUD operations

### Views Flow
1. `CardListView` - Apple Wallet-style stacked card UI with tap-to-expand animation
2. `FullScreenCardView` - Full-screen card display (tap to flip, swipe down to dismiss)
3. `EditCardView` - Card editing with scanner integration (accessed via long-press)
4. `AddCardView` - Card creation with scanner integration

### Custom Scanner (`AutoCaptureScanner.swift`)
Custom camera implementation using AVFoundation + Vision framework:
- `VNDetectRectanglesRequest` for card detection with relaxed thresholds
- Auto-captures after card is stable for ~1 second
- Perspective correction via `CIFilter.perspectiveCorrection()`
- Text-based orientation detection using `VNRecognizeTextRequest` (respects portrait cards)
- Manual capture fallback button

### Image Enhancement (`ImageEnhancer.swift`)
Core Image filters for card legibility: auto-adjust, sharpen, noise reduction, unsharp mask.

### Logging (`AppLogger.swift`)
Uses `os.Logger` with categories: `UI`, `Data`, `Scanner`. Filter in Xcode console with `subsystem:com.kevinthau.wallet`.

## Key Technical Notes

- Development Team ID: `3JXY2MS2Y3`
- Bundle ID: `com.kevinthau.wallet`
- iOS 17.0+ target, Swift 5.9
- Portrait-only orientation, requires full screen
- Entitlements: iCloud (CloudKit) and key-value store
- Layout constants defined in `Constants.swift`
