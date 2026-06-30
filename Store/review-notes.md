# App Review Notes

Thank you for the review. In this build we addressed all reported issues.

1. Support URL:
   We updated the support page with contact information, support instructions, FAQ, safety information, privacy information, and a last-updated date.

2. Home folder selection:
   After selecting the Home folder, the app immediately starts analysis and shows live progress, then populated results, an empty-results message, or a permission message. If a saved folder permission fails, the app clears that saved access internally and asks the user to select the Home folder again.

3. Folder permission and sandboxing:
   The app is sandboxed and uses only App Store-compatible user-selected file access. It asks the reviewer/user to choose the signed-in user's Home folder through the standard macOS folder picker, stores an app-scoped security bookmark, and rejects /Users, system folders, lookalike folders, and other user folders. The app does not request administrator privileges, Full Disk Access, temporary absolute-path exceptions, automation permissions, shell scripts, or unsandboxed system access. Protected personal folders such as Documents, Desktop, Downloads, Pictures, Movies, and Music are not scanned.

4. Privacy manifest:
   The app privacy manifest declares the required-reason APIs used by the app: file timestamps for age-based cleanup checks inside the user-approved Home folder, disk-space information for the local before/after space readout, and app-owned UserDefaults access for local app state. The app collects no data, tracks no users, uses no third-party SDKs, and uploads no file metadata.

5. Demo Mode:
   The app starts with Open Full Version for real cleanup or Open Demo for sample data. Demo Mode is a separate selectable sample workflow, not embedded inside real cleanup. It lets App Review choose LOW, MID, HIGH, or APPLICATION LEFTOVERS sample analysis directly so all app pages and features can be inspected. Demo Mode uses the same action wording as the full version while the surrounding demo notes state that no real files are scanned, moved, or deleted. Skip demo is available throughout the demo.

6. Safety and wording:
   We revised app copy to avoid misleading or exaggerated claims. The app now uses neutral wording such as estimated reclaimable space, review before removing, and move to Trash. Files are never removed without user confirmation, HIGH cleanup requires typing DELETE, Application Leftovers are never selected automatically, and non-actionable areas such as backups, Trash, AI models, Docker data, and Time Machine snapshots are not shown as cleanup issues.

7. Application Leftovers:
   Application Leftovers uses documented macOS APIs and user-approved Home folder access. It groups possible leftovers by bundle identifier, verifies no matching installed app is found, shows Home-relative evidence paths, and moves only selected items to Trash through NSWorkspace.

8. Live progress:
   During real cleanup analysis and cleanup, the activity screen shows one discreet current-processing row using shortened Home-relative paths such as `~/Library/Caches/...`. It does not show the full `/Users/...` Home path and is not a persistent file log.

To test Demo Mode:
Open the app -> click Open Demo -> choose LOW, MID, HIGH, or APPLICATION LEFTOVERS sample analysis -> inspect the populated sample results -> click Skip demo at any time.

To test real analysis:
Open the app -> click Open Full Version -> choose a cleanup mode -> select the Home folder -> analysis starts automatically -> review items before confirming.

No demo account is required. The app contains no login, network service, analytics, advertising, in-app purchases, or third-party SDKs.
