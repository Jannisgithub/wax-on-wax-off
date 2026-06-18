# Wax on/Wax off

Native, privacy-first macOS storage cleanup with a deliberately small workflow:

```text
SELECT LOW / MID / HIGH / LEFTOVERS
RUN ANALYSIS
REVIEW EXACT CANDIDATES
CONFIRM AND DELETE
```

The App Store target is a Swift 6 SwiftUI app. It is sandboxed, uses only Apple frameworks, has no network dependency, and scans only the Home folder the user explicitly approves through the macOS folder picker.

## Cleanup modes

- `LOW`: old user caches, logs, and crash reports with a 30-day rule.
- `MID`: LOW plus known re-downloadable app caches with a 14-day rule.
- `HIGH`: MID plus approved developer and package caches with a 7-day rule. Applying HIGH requires typing `DELETE HIGH`.
- `LEFTOVERS`: inactive bundle artifacts that do not match an installed app. Nothing is preselected and approved items move to Trash.

Xcode.app, Trash, Time Machine snapshots, personal files, and protected system locations are review-only. The App Store build does not run shell commands, request root access, or depend on Python.

## Build

Requirements:

- macOS 14 or later
- Xcode 26 or another App Store Connect-supported production Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
xcodegen generate
xcodebuild \
  -project WaxOnWaxOff.xcodeproj \
  -scheme WaxOnWaxOff \
  -configuration Debug \
  test
```

The product bundle identifier is `com.jannis.waxonwaxoff`. Version 1.0 is free, English-only, and targets the Mac App Store Utilities category.

## Privacy and support

The static GitHub Pages source is in [`docs/`](docs/). App Store copy and App Review notes are in [`Store/`](Store/).

Legacy Python/AppKit prototype files in the original working folder are excluded from the public repository, Xcode target, and release bundle.
