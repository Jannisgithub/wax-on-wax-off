# Wax on/Wax off

Native, privacy-first macOS storage cleanup with a deliberately small workflow:

```text
SELECT LOW / MID / HIGH / APP LEFTOVERS
RUN ANALYSIS
REVIEW EXACT CANDIDATES
CONFIRM SELECTED PLAN
```

The App Store target is a Swift 6 SwiftUI app. It is sandboxed, uses only Apple frameworks, has no network dependency, and scans only the Home folder the user explicitly approves through the macOS folder picker. It rejects `/Users`, system folders, other user folders, and lookalike folders, and it does not request administrator privileges or Full Disk Access.

## Cleanup modes

- `LOW`: old user caches, logs, and crash reports with a 30-day rule.
- `MID`: LOW plus known re-downloadable app caches with a 14-day rule, including closed-app Chrome and Spotify disk caches while preserving profiles and persistent storage.
- `HIGH`: MID plus developer/package caches and closed-app render caches. HIGH-only findings start unchecked, and the app recommends MID when the additional immediate cleanup is under 1 GB. Applying HIGH requires typing `DELETE`.
- `APPLICATION LEFTOVERS`: inactive application data that no longer matches an installed app. Nothing is preselected and selected items move to Trash.

HIGH is limited to documented cache locations inside the approved Home folder. Personal folders such as Downloads, Desktop, Documents, Pictures, Movies, and Music are not scanned. Project folders, device backups, Xcode archives/runtimes, AI models, Docker data, Trash, Time Machine snapshots, personal files, and protected system locations are not shown as cleanup issues.

The app keeps a local cleanup receipt per candidate and shows how much of a previous direct cleanup remains reclaimed. Results distinguish direct removal from items moved to Trash and show the system-reported available-space change. Cleanup history contains aggregate sizes and hashed candidate IDs, not file contents or file lists.

The App Store build does not run shell commands, request root access, or depend on Python.

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
