# Spec — Command Manager MVP (status-bar app)

Source: the agreed software plan (`cezar-software-plan.md`, 2026-11-18). This spec records the
implementation decisions made against it; product scope is unchanged.

## Decisions taken during implementation

| Topic | Decision | Why |
| --- | --- | --- |
| Project format | Swift Package (`CommandManagerCore` library + `CommandManager` executable) plus `scripts/build-app.sh` that assembles an `.app` with `LSUIElement` | The build machine has only Command Line Tools (no Xcode); SwiftPM builds and tests without it. |
| UI host | `NSStatusItem` + `NSPopover` hosting SwiftUI; `NSApp.setActivationPolicy(.accessory)`; no scenes | `MenuBarExtra` needs macOS 13; plan targets 12. |
| Process spawn | `posix_spawn` of `/bin/zsh -lc <command>` with `POSIX_SPAWN_SETPGROUP` (own process group), `CLOEXEC_DEFAULT`, stdin `/dev/null` | Stop must reach children of the shell (`cd x && npm start`) without killing unrelated processes; Foundation `Process` cannot set a process group. The group is the confirmed stop scope. |
| Signals | Only via the in-session handle, and never after the child was reaped | Prevents signalling a reused PID. |
| Restore after restart | `runtime.json` keeps `ProcessIdentity` (PID + kernel start time from `proc_pidinfo`) of active commands; on launch only the *same* process (PID and start time match) marks the command `unknown` (shown, never signalled) and skips its auto-start | Plan §4 / acceptance 8; a PID reused after reboot must not block auto-start. |
| Login item on macOS 12 | One app-level LaunchAgent (`open -g -a <app>`), not `SMLoginItemSetEnabled` | A helper bundle cannot be produced without Xcode; still app-level only, no per-command launchd jobs. macOS 13+ uses `SMAppService.mainApp`. |
| Quit | `applicationShouldTerminate` → SIGTERM to every owned process group, wait up to 3 s, then SIGKILL the rest, then terminate | "Commands do not run while the app is not running." |
| Leftover group members | When the shell exits during Stop but group members survive, the group gets SIGTERM again and SIGKILL after ≤3 s; after an unexpected exit a warning is logged and the group is stopped on quit | Safe only while the group is alive (a group ID is not reused while the group exists), so leftover entries are pruned every second once the group empties and are never signalled afterwards. |
| Unknown state | Start is refused until the user presses Clear status (no signal is ever sent to the old PID) | Avoids silently duplicating a leftover service. |
| Quit in progress | `stopAll()` sets a shutdown flag: pending restarts are cancelled and Start is refused | A command must not start during the quit grace period and then only receive SIGKILL. |
| Delete | Refused while the command is starting/running/stopping (Stop first); removes definition + auto-start flag; keeps working folder and log files on disk | Deleting a live command would leave an untracked process; plan §6 says logs are not deleted. |
| Restart | Stop, then start the definition *as saved when the stop completes*; skipped with a message if it was disabled/deleted meanwhile | Acceptance 6. |
| Logs | `\r`, `\r\n`, `\n` end lines; a line is flushed at 64 KiB without newline; write errors never raise | Progress-bar output must not grow memory; full disk must not crash the app. |
| Stop timeout | 10 s, then Force Stop (SIGKILL) behind a confirmation | Plan §5.6. |

## Acceptance traceability

| # | Check | Covered by |
| --- | --- | --- |
| 1 | No Dock icon/main window; status icon opens panel | `Info.plist` `LSUIElement`, `main.swift` accessory policy, `AppDelegate` popover — manual QA |
| 2 | Empty state → add form; valid command persists; bad folder rejected with reason | `ServiceListView.emptyState`; `AppModelTests.savePersistsAcrossRelaunchAndDoesNotStart`, `invalidWorkingDirectoryIsNotSaved`; `ValidationTests` |
| 3 | starting → running, PID/start time, stdout+stderr in receipt order | `SupervisorStateMachineTests.startGoesStartingThenRunningWithPID`; `PosixRunnerIntegrationTests.capturesStdoutAndStderrInOrderAndExitsCleanly`; `LogStoreTests` |
| 4 | Stop: stopping → stopped; timeout → Force Stop only after confirmation | `stopGoesStoppingThenStopped`, `stopTimeoutOffersForceStopOnlyThen`, `stopTerminatesWholeProcessGroup`, `unresponsiveProcessNeedsForceStop`, `quitEscalatesToKillForStubbornCommands`; list + detail confirmation alerts |
| 5 | Error exit → failed/exited with code, error, log kept | `nonZeroExitIsFailedAndZeroIsExited`, `nonZeroExitIsFailed`, `missingExecutableIsFailedNotCrash`, `deletedWorkingDirectoryFailsWithReason`; log is file-backed |
| 6 | Disable blocks Start, keeps definition/log; re-enable allows Start | `disableBlocksStartAndReenableAllowsIt`, `disabledServiceCannotStart` |
| 7 | Login item; only `enabled && autoStart` start at launch; failure not misreported | `launchAutoStartsOnlyEnabledAutoStartCommands`, `loginItemFailureIsReportedAndStatusNotFaked`, `launchAgentAdapterWritesAndRemovesAppLevelPlist` |
| 8 | No signal based on stale PID; unverified → unknown | `previousSessionPIDIsUnknownAndNeverSignalled`, `launchSkipsAutoStartWhenPreviousProcessIsUnverified`, `reusedPIDFromAnotherBootIsNotUnknown`, `ProcessIdentityTests` |
| 9 | Delete confirms, removes definition + auto-start, keeps folder | `deleteRequiresStopThenRemovesDefinitionAndKeepsFolder`, `forgetIsRefusedWhileProcessIsOwned`; detail view delete alert |
| 10 | VoiceOver labels, announcements, keyboard, not color-only | `StatusBadge` (symbol + text), accessibility labels/hints, `NSAccessibility` announcements in `AppDelegate`, ⌘N / Return / Esc / ⌘Q shortcuts — manual VoiceOver QA |

## Not covered by automated tests (needs manual QA)

- Popover rendering, VoiceOver pass, Increase Contrast, keyboard-only flow.
- Real login-item registration on macOS 12 and 13+ (needs the app in `/Applications`, a real login).
- Code signing/notarization for distribution (build script ad-hoc signs only).
