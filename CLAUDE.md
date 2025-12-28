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

### Views Flow
1. `CardListView` - Apple Wallet-style stacked card UI (main screen)
2. `FullScreenCardView` - Full-screen card display for showing to others (tap to flip front/back)
3. `CardDetailView` - Edit card details (accessed via long-press)
4. `AddCardView` / `EditCardView` - Card creation/editing with scanner integration

### Custom Scanner (`AutoCaptureScanner.swift`)
Custom camera implementation using AVFoundation + Vision framework:
- `VNDetectRectanglesRequest` for card detection with relaxed thresholds
- Auto-captures after card is stable for ~1 second
- Perspective correction via `CIFilter.perspectiveCorrection()`
- Text-based orientation detection using `VNRecognizeTextRequest` (respects portrait cards)
- Manual capture fallback button

### Image Enhancement (`ImageEnhancer.swift`)
Core Image filters for card legibility: auto-adjust, sharpen, noise reduction, unsharp mask.

## Key Technical Notes

- Development Team ID: `3JXY2MS2Y3`
- Bundle ID: `com.kevinthau.wallet`
- iOS 17.0+ target, Swift 5.9
- Entitlements: iCloud (CloudKit) and key-value store
