# Command Manager

A macOS status-bar app (SwiftUI, macOS 12+) that keeps the commands you use to run local
services in one place: add, edit, delete, enable/disable, start/stop/restart, auto-start when
the app opens at login, working folder, environment, live status, PID and per-command logs.
There is no main window and no Dock icon.

## Build and run

Requires Swift 5.9+ (Xcode or just the Command Line Tools).

```bash
scripts/build-app.sh            # -> build/CommandManager.app (ad-hoc signed, not sandboxed)
open build/CommandManager.app
scripts/test.sh                 # unit + integration tests (Swift Testing)
```

Move the app to `/Applications` before turning on **Open at login** (gear button › Settings, or ⌘,). Settings also has the light/dark appearance choice (System, Light, Dark) and shortcuts to the logs and data folders.

## Groups and ordering

Put commands into groups (folder button, or right-click › Group). The list shows a group as one
row with its count and running/failed totals; click it to expand its commands, ▶/■ starts or stops
them all. Drag rows to sort: a command dropped on another command takes its place (joining or
leaving that group), dropped on the lower half of a group row goes inside it, on the upper half goes
before it. Groups sort among top-level rows the same way. Right-click for Move Up/Down, Rename,
Ungroup, Start/Stop All. Order, groups and expanded state are saved in `services.json`.

## Add by drag and drop

Drop a script, executable, `.app` or project folder on the menu-bar icon or on the open popover:
the add form opens prefilled — working folder = the file's folder, name = file name, command =
how to run it (`./file` when executable, else `bash`/`python3`/`node`/`npx tsx`/`ruby`/`java -jar`/
`go run`… by extension; a `.app` runs its bundle executable; a project folder or `package.json`
gets `npm|pnpm|yarn|bun run dev` (or `start`), `docker compose up`, `cargo run`, `go run .`,
`python3 manage.py runserver` or `make`). Review and Save; nothing starts on its own.
Same from the terminal: `cmgr add ./server.sh` or `cmgr add ~/code/web --restart`.

## Command line (`cmgr`) and AI agents (MCP)

The app bundle ships a `cmgr` tool (`CommandManager.app/Contents/MacOS/cmgr`). Every time the app
opens it links it as `cmgr` into the first writable folder on your login-shell PATH
(`/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, `~/bin`; falling back to `~/.local/bin` with a
hint if none is on PATH). Installing the `.app` is all that is needed; moving it re-points the link.
An existing `cmgr` that is a regular file is never overwritten.

```bash
cmgr list                                   # all commands, state, PID
cmgr status api                             # state, exit code, last error, definition
cmgr logs api -n 200 --errors               # stderr + error-looking lines; --grep TEXT, --source out|err|sys, -f to follow
cmgr context                                # markdown snapshot (table + recent errors) to paste into an AI chat
cmgr start|stop|restart|kill api
cmgr add --name api --cmd "npm run dev" --cwd ~/code/api --env PORT=3000 --auto-start --restart
cmgr edit api --restart false               # turn automatic restart off
cmgr add web -- npm run dev                 # short form
cmgr add ./scripts/serve.sh                 # infer folder + command from a file/folder/.app
cmgr edit api --cmd "pnpm dev" --enabled false
cmgr move api 1                             # reorder (1 = top); in the app: drag a row or right-click › Move…
cmgr group create backend api db            # group ls | rename | delete | add G svc [pos] | remove svc | move G pos | start G | stop G
cmgr add worker --group backend -- node worker.js
cmgr delete api [--clear-logs]
cmgr list --json                            # every command accepts --json
```

`<service>` is a name (case-insensitive; a unique fragment is enough) or an id. `cmgr` talks to the
running app over a user-only Unix socket (`control.sock`); with the app closed, reads and definition
edits work on the saved files, and `start`/`stop`/`restart` open the app first.

**MCP server** for Claude Code, Cursor, Claude Desktop…: `cmgr mcp` (stdio). Set it up with
`claude mcp add command-manager -- /Applications/CommandManager.app/Contents/MacOS/cmgr mcp` (use the
absolute path: AI clients often start without your shell PATH), or print a JSON snippet with `cmgr mcp-config`.
Tools: `get_context`, `list_services`, `service_status`, `read_logs`, `start_service`, `stop_service`,
`restart_service`, `force_stop_service`, `clear_status`, `create_service`, `update_service`,
`enable_service`, `disable_service`, `move_service`, `delete_service`, `clear_logs`, `create_group`,
`rename_group`, `delete_group`, `set_service_group`, `move_group`, `start_group`, `stop_group`.
Agents get full read/write access with no confirmation step (agreed policy), so only connect
agents you trust; log output is capped (≤2000 lines / 200 KB per call) but may contain secrets.

## How it works

- Each command runs as `/bin/zsh -lc "<command>"` in its working folder (home folder when empty),
  in its own process group. Environment = your login shell's environment (captured once at app
  launch by running your user shell as `-i -l`, so `PATH` set in `~/.profile`, `~/.bash_profile`,
  `~/.zprofile` or `~/.zshrc` applies — e.g. Go, nvm), with
  `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` appended when missing, plus your
  `KEY=VALUE` lines. Exit code 127 (command not found) logs the PATH that was used.
- Standard edit shortcuts work in every text field and log: Cmd+C/V/X/A/Z, Cmd+Shift+Z, and the
  Ctrl equivalents (Ctrl+C/V/X/A/Z, Ctrl+Shift+Z / Ctrl+Y).
- The log button on a command row (or **Expand** in its log, or *Show Log* in its context menu)
  opens a resizable log viewer window; the log button on a group header (or *Show Group Log*) opens
  one window with every command of the group merged in time order, with a colored Command column.
  Each viewer window has one row
  per log line (time, type, message), **Following / Paused** to stop auto-scrolling while you read,
  **Wrap rows**, and a detail pane for the selected line that shows it in full — JSON lines (or a
  JSON payload at the end of a line) are pretty-printed. Cmd+W closes it. Scrolling up pauses
  following and, at the top, loads earlier lines (also from rotated files); Cmd+C copies the
  selected rows. Right-click selected text in the detail pane (or the popover log) for *Unescape JSON
  & Copy* (plain or formatted). Cmd+F jumps to the filter (selected log text becomes the filter) (also in the popover log); text matching the filter is
  highlighted in the rows, the detail pane and the popover log. The viewer reads only new bytes each second and keeps at most 50,000 lines /
  32 MB in memory; older lines stay in the log file.
- Commands run only while the app is open. Quitting sends SIGTERM to everything it started and
  SIGKILL to whatever is still alive 3 s later. Stop a command before deleting it.
- **Start when app opens**: after launch the app starts every command that is *enabled* and has
  this flag. Combined with *Open at login* this brings services back after a reboot.
  Commands are never registered with launchd themselves.
- Stop sends SIGTERM to the command's process group; after 10 s the UI offers **Force Stop**
  (SIGKILL, with confirmation). A crash or non-zero exit shows **Failed**.
- **Restart on exit** (per command, off by default): when the command exits or crashes on its own
  (any exit code or signal), it is started again after 1 s, then 2 s, 4 s … capped at 1 min between
  tries; a run lasting 1 min or more resets the wait to 1 s. Stop (or Start, Clear status, disabling,
  turning the option off, deleting, quitting) cancels a scheduled restart. A manual Stop/Restart never
  triggers it.
- If the app finds a process from a previous session that may still be alive, the command is shown
  as **Unknown** with its old PID. The app never signals a PID it did not launch in this session.
- Open at login uses `SMAppService` on macOS 13+, and a single per-user LaunchAgent that opens
  the app on macOS 12.

## Files

`~/Library/Application Support/CommandManager/`

| Path | Contents |
| --- | --- |
| `services.json` | Command definitions (versioned JSON, atomic writes) |
| `runtime.json` | PIDs of running commands, used only to flag *Unknown* after a crash |
| `Logs/<id>.log` | Timestamped stdout/stderr/system lines; 10 MB per file, 5 files kept |
| `control.sock` | Local socket for `cmgr` / MCP (mode 0600, same-user peers only) |

`CMGR_HOME=/some/dir` makes both the app and `cmgr` use another data folder (testing); the app then
does not install the `cmgr` link.

Commands, environment values and logs are plain text — don't store secrets in them.

## Layout

- `Sources/CommandManagerCore` — model + validation, store, log store, process runner,
  supervisor state machine, login-item adapters, `AppModel` facade (all unit-tested).
- `Sources/CommandManagerCore/Control*.swift`, `MCPServer.swift`, `CLIInstaller.swift` — control
  operations, socket server/client, MCP (JSON-RPC over stdio), PATH link installer.
- `Sources/cmgr` — the CLI.
- `Sources/CommandManager` — `NSStatusItem` + `NSPopover` hosting the SwiftUI views.
- `Tests/CommandManagerCoreTests` — unit tests with a fake runner and integration tests with real processes.
- `docs/specs/command-manager-mvp.md` — spec and acceptance-check traceability.

## App icon

`Resources/AppIcon.icns` is drawn by `swift scripts/make-icon.swift` (add `--preview` with an output
folder to also get a 1024 px PNG). Edit the script and re-run it to change the icon.
