# App Review Notes

Wax on/Wax off is a local, sandboxed macOS cleanup utility. It contains no login, network service, analytics, advertising, in-app purchases, or third-party SDKs.

## Review flow

1. Choose `LOW`, `MID`, `HIGH`, or `LEFTOVERS`.
2. Select `RUN`.
3. On the first run, the standard macOS folder picker asks for a Home folder. The app only inspects fixed cache, log, developer-cache, and inactive-app-artifact locations inside that user-selected folder.
4. Analysis is read-only. Reviewers can inspect and change the candidate selection before continuing.
5. Select `CONFIRM & DELETE` and approve the native confirmation dialog.
6. `HIGH` additionally requires the exact phrase `DELETE HIGH` because it may remove rebuildable developer caches.
7. `LEFTOVERS` moves selected items through `NSWorkspace.recycle`; it does not permanently delete them.

## Sandbox and safety behavior

- Entitlements are limited to App Sandbox, user-selected read/write access, and app-scoped security bookmarks.
- The bookmark is stored locally in the app container and can be removed with **Reset Folder Access** in the app menu.
- The app rejects symlink components, paths outside the approved folder, changed timestamps, and missing paths during apply.
- Known app-specific cache targets are skipped while their owning application is running.
- Xcode.app, Trash, Time Machine snapshots, personal documents, and protected system paths are never modified.
- The app uses only Apple frameworks and does not launch shell commands, request administrator privileges, or depend on optional runtimes.

If the review Mac has no eligible old cache data, analysis correctly returns an empty plan. No demo account is required.

