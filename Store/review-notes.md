# App Review Notes

Wax on/Wax off is a local, sandboxed macOS cleanup utility. It contains no login, network service, analytics, advertising, in-app purchases, or third-party SDKs.

## Guideline 2.4.5(v) response

Build 17 removes any path that could cause administrator authentication. The first-run folder picker accepts only the signed-in user account Home folder and rejects /Users, system roots, lookalike folders, and other user folders. Cleanup analysis and apply also skip files or folders that are not owned by the signed-in user, including items moved through NSWorkspace.recycle, so the app never asks for administrator privileges.

## Guideline 2.1(a) response

Build 17 fixes the Home-folder recognition bug reported against build 5. The first-run picker now resolves the real signed-in account Home folder from the macOS account record and explicitly avoids using the app sandbox container `Data` directory as the expected Home folder. The selected folder is accepted when it matches the normalized account Home path, including `/System/Volumes/Data/Users/...` aliases, or the same filesystem identity. `/Users`, system roots, other user folders, and the app container remain rejected.

## Review flow

1. Choose `LOW`, `MID`, `HIGH`, or `LEFTOVERS`.
2. Select `RUN`.
3. On the first run, the standard macOS folder picker asks for a Home folder. The app inspects only documented cleanup locations inside that folder; project folders are not scanned.
4. Analysis is read-only. Reviewers can inspect and change the candidate selection before continuing.
5. Select `CONFIRM & DELETE` and approve the native confirmation dialog.
6. `HIGH` additionally requires the exact phrase `DELETE HIGH`. Every HIGH-only action is unselected by default. The app recommends MID when HIGH adds less than 1 GB of immediate cleanup.
7. `LEFTOVERS` and reviewed installers/downloads move through `NSWorkspace.recycle`; they do not count as immediately reclaimed storage.
8. The result separates permanently deleted bytes from bytes moved to Trash and shows the system-reported available-capacity change.

## Sandbox and safety behavior

- Entitlements are limited to App Sandbox, user-selected read/write access, and app-scoped security bookmarks.
- The bookmark is stored locally in the app container and can be removed with **Reset Folder Access** in the app menu.
- The app rejects symlink components, paths outside the approved folder, paths not owned by the signed-in user, changed timestamps, and missing paths during apply.
- Known app-specific cache targets are skipped while their owning application is running.
- Project folders are not scanned or modified.
- Device backups, Xcode archives/runtimes, AI models, Docker data, Xcode.app, Trash, Time Machine snapshots, personal documents, and protected system paths are never modified.
- The app uses only Apple frameworks and does not launch shell commands, request administrator privileges, or depend on optional runtimes.
- Cleanup memory stores only aggregate sizes, timestamps, mode, and hashed candidate IDs in the app container. It can be removed with **Reset Cleanup Memory**.

If the review Mac has no eligible old cache data, analysis correctly returns an empty plan. No demo account is required.
