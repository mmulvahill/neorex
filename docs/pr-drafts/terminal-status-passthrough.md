feat: pass terminal titles and program status through to Rex panes

## Why

Run Claude Code in a plain Rex pane and the tab takes its name from your first prompt, shows a spinner while it works, and marks the tab when it needs you. Run it in a Neovim terminal inside neorex and Rex sees none of it: the tab says `Window 1a2b3c4d`.

Rex gets those from two things the program writes to its terminal: the title (OSC 0/2) and its status, as [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status). Inside neorex the program writes to Neovim's terminal, not the pane's, so neither reaches Rex. Claude Code doesn't even report its status there: it first asks whether status is supported (`OSC 7501 ; ?`) and only reports if the terminal answers, and Neovim doesn't.

This matters most for anyone who runs agents in Neovim terminals so they can move around and yank from the output in normal mode.

## What changed

**windows.lua**
- `TermRequest` answers `OSC 7501 ; ?` for the terminal, as Rex would, and keeps each terminal's status records as the spec says: each report replaces its record, `clear` removes a record and those under it, or every record without an id.
- A `dictwatcheradd` on each terminal's `b:term_title` follows its title.
- A new `neorex_term` note tells the daemon a window's terminal title and records whenever they change, and from `BufWinEnter` and `WinNew` when a window shows another buffer (empty for a buffer that isn't a terminal).
- `TermClose` drops `working`, `blocked` and `idle` records and keeps `done` and `error`, as the spec says a terminal does when its program exits.

**Daemon**
- New `TermStatus`: a window's title and records, and `sync`, which writes only what changed between what a pane last showed and what it should show now, clearing records by id.
- `Daemon` keeps what each window should show; `draw` syncs each tiled pane before its frame, so the sequences never land inside one. Panes made before the note, or notes before their pane, line up on the next draw.
- `Surface.destroy` clears the title and records it set, so the pane neorex ran in doesn't keep "working" and Claude's title after neorex exits.

## Safety

Everything forwarded comes from a program in a Neovim terminal and goes to the real pane, where it could otherwise end the sequence early and send Rex anything, such as OSC 52 to write the clipboard. So a report is sent only if it's printable ASCII and within the spec's 4096 bytes, ids must match the spec's grammar, and titles lose C0 and C1 controls and are cut to 256 bytes on a character boundary.

## Tradeoffs

- Only tiled panes. A terminal in a float (toggleterm and the like) doesn't reach its Rex floating pane yet; picking which of a group's floats a floating pane speaks for seemed better as its own change.
- A terminal no window shows has nowhere to show its status. The spec's child records could carry those on another pane later.
- Rex's `process` still shows `neorex` as the foreground process: the program runs on Neovim's pty, so that can't be passed through. Tabs and status don't depend on it.
- Rex's tab icon still says "terminal", not Claude Code. Rex seems to pick the icon from the pane's foreground process name, and that's neorex's helper, while the records carry `app=claude-code` exactly as in a plain pane. Taking the icon from a status record's `app` would be Rex's side.
- neorex always answers the support question, since it only runs inside Rex.

## Blast radius

Only windows showing a terminal buffer change what Rex shows: their pane gets the terminal's title and status. Other panes write nothing new. The autocmds are in neorex's augroup and only act on terminals neorex saw open.

## Verification

On macOS (Darwin 25.3.0, arm64) and Linux (x86_64), both with Zig 0.17.0 and Neovim v0.13.0-dev-2001+g7437121ea3. Linux ran with a local epoll loop in place of kqueue, which isn't part of this PR.

- `zig build test -Dgolden`: 44/44 steps, 188/188 tests on macOS (124 unit, 64 golden); the same counts on Linux. `zig fmt --check` is clean.
- Unit tests for `TermStatus`: syncing sends only what changed, clears by id, clears a parent's children once and resends kept ones, a lost root record clears everything, `reset`, and that escape sequences, BEL and C1 controls in reports and titles can't get through.
- New `windows.zig` test against a real Neovim: a `:terminal` that only reports after its question is answered sets a title and a record, and the window's note carries both; `:enew` empties it and `:buffer #` brings it back. With the answer removed from the Lua, the test fails.
- By hand in Rex on macOS, with Claude Code in `:terminal claude`, reading the pane with `rex block call title` and `program_status`:
  - Once Claude Code starts, the title is `Claude Code` and there's one record, `idle`, app `claude-code`.
  - A prompt to create a file, with Claude Code in manual permission mode: the title became Claude's summary of the prompt, `Neorex-e2e.txt file creation`, and the status went `working`, then `blocked` with `kind=permission` and `msg` "approve Write: /tmp/neorex-e2e.txt", then `working` once approved, then `done`.
  - `:enew` empties the title and clears the records; `:buffer #` brings both back.
  - `:vsplit` gives the new pane the same title and the `done` record.
  - `:qa!` closes the split and leaves the remaining pane with no title and no records.
  - In the Rex app, the tab takes its name from the first prompt and shows the status indicators. Its icon is the generic terminal one; see Tradeoffs.
- The same checks on Linux (`working` there was too quick to catch).
