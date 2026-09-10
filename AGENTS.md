# ClipBridge

Clipboard transfer between Sikai's iPad and this Mac (MacBook Air, macOS 26).
Two layers: Apple's Universal Clipboard, improved and instrumented; and an SSH
bridge driven by iPad Shortcuts for when that fails.

Start any session by reading "Hard-won findings" below. Most of it was learned
by measurement after a wrong guess, and several of the traps are invisible.

## Commands

    clip            state, which route works on this network, health
    clip fix        full check, restart sharingd, then verify against the iPad
    clip last       put the last clip back on the clipboard
    autopaste up    auto-paste clips arriving from the iPad
    autopaste down  stop that

    rarely: clip test | clip hist | clip check | clip net | clip key

Only `clip` and `autopaste` are on PATH (symlinked into `~/.local/bin`).
Everything in `bin/` still runs directly.

## Layout

    bin/            all commands; `clip` dispatches to the rest
    src/            Swift sources - prefetch daemon, image read/write, keep-warm
    ClipBridgeAgent.app/   the prefetch daemon, bundled and signed
    launchagents/   the two background services
    install.sh      rebuild, re-sign, reload. Run after any src/ change.
    README.md       user-facing write-up

Runtime data (NOT in this folder): `~/Library/Application Support/ClipBridge/`
- `prefetch.log`  every pasteboard change, the primary evidence source
- `bridge.log`    every SSH transfer, with the route it arrived on
- `history/`      last 300 text clips, backing `clip last`
- `no-keepwarm`   presence disables keep-warm (currently present)
- `autopaste`     presence enables auto-paste

## Architecture

**Prefetch daemon** (`ClipBridgeAgent.app`, launchd, KeepAlive). Polls
`changeCount` every 0.35s. On a change it reads the data, which forces an
incoming Universal Clipboard payload across immediately instead of lazily at
paste time. Also records history and drives auto-paste.

**Watchdog** (`clipwatch`, every 60s). Detects `sharingd` wedging and restarts
it. Also does a preventive restart at 18h uptime while idle.

**SSH bridge**. iPad Shortcuts call `clip-recv` (Push) and `clip-send` (Pull)
over SSH. Two host options: `MacBook-Air.local` on permissive networks,
`your-mac.tailnet-name.ts.net` when a network blocks device-to-device traffic.
`clip` reports which applies.

## Traps that will cost you hours

**Signing.** The agent MUST be signed with the `WindowDeck Dev` certificate
already in the keychain. Ad-hoc signing has no stable designated requirement,
so macOS grants Accessibility and then silently drops it minutes later. This
cost several rounds of "why won't it stick". `install.sh` handles it; do not
change the signing line.

**Shortcuts payloads go on stdin, never argv.** Putting base64 in the command
string fails with "Unable to send channel request" for anything beyond a short
string - the SSH exec limit is far below ARG_MAX. Set the action's Input field.

**A Shortcuts variable typed as text looks identical to a real one** and fails
silently. `clip-recv` logs every invocation and every failure precisely so this
is visible.

**`pbcopy` / `pbpaste` are text-only.** Images need `clip-image` and
`clip-setimage` (NSPasteboard). `clip-recv` sniffs magic bytes so the Shortcut
needs no branch; `clip-send` prefixes `__CLIPBRIDGE_PNG__` so Pull can branch.

**`public.plain-text` is a different UTI from `.string`** (public.utf8-plain-text).

**`grep -q` in a pipeline under `set -o pipefail`** inverts checks: grep exits
early, the SIGPIPE fails the upstream command. Bit `clipstatus` once.

**macOS ships bash 3.2** - no `mapfile`, no `etimes` in `ps`.

**macOS redacts the Wi-Fi SSID** without location permission. Identify networks
by gateway MAC instead.

## Findings, measured not guessed

**~15% of clips from the iPad arrive hollow** - an announcement carrying a
5-byte `link.contentkit.name` and no payload. 32 of 35 have nothing after them.
Not fixable from the Mac: the payload never exists, never arrives late, and
there is no way to ask the iPad to resend. Copying again is the only remedy.
A red banner with a sound now fires immediately so the failure is known at once.

**Retry on hollow clips: removed.** 0 recoveries in 9 attempts, and the wait
blinded the poll loop for 7 seconds each time.

**Keep-warm: disabled**, kept only as dead code. Built on the theory that the
Mac->iPad link goes cold; the data refutes it (hollow clips follow a 53s median
gap, good clips 63s). It also cleared the pasteboard before rewriting, a window
in which the iPad could fetch nothing - a plausible cause of Mac->iPad failures.

**Universal Clipboard uses Bluetooth LE plus AWDL, never the network.** It kept
working on an office /22 with client isolation where SSH could not connect.
The Wi-Fi radio must be on even on ethernet.

**The directions are asymmetric and always will be.** iPad->Mac can be
prefetched because the Mac can run a daemon. Mac->iPad cannot: iOS runs no
third-party code at copy time and Shortcuts has no clipboard trigger. There is
no observability into Mac->iPad at all - the only evidence it works is the
occasional echo coming back, 5 out of 1011 local copies.

**`sharingd` fails in two distinct ways**: wedged (announcements arrive empty,
persistently) and silent (nothing arrives at all). A clean `clip` report does
NOT mean it is working - every external check can pass while it moves nothing.

## Auto-paste

Synthesises Cmd-V via CGEvent when a clip arrives from the iPad. Needs
Accessibility, hence the .app bundle. Three guards, each added after a real
failure:
- re-announcement: the iPad re-advertises a clip repeatedly; without this it
  pasted the same image five times
- echo: a clip copied on THIS Mac returns via the iPad and looks incoming;
  without this it pasted the user's own clipboard back at them
- hollow: nothing to paste, red banner instead

It fires into whatever window is focused. Multi-line text landing in a terminal
can execute. That risk is inherent, not a bug.

## Working style Sikai expects

Measure before claiming. Several confident diagnoses here were wrong and were
caught by looking at logs: "the restart fixed it" (it had not), "the payload
arrives late" (0 for 9), "empty means empty" (it meant empty of the types being
read). Pull the numbers first.

Say plainly when something cannot be done rather than building around it.
Keep the command surface small - it was consolidated from six commands to two
on request.

## Open

- Mac->iPad reliability is unmeasured and probably unmeasurable from here
- Whether disabling keep-warm improves Mac->iPad (retest)
- Handover doc: https://Codex.ai/code/artifact/a5e75f04-a986-4ef5-ba5c-8b5577162bb2
