# ClipBridge

Reliable clipboard transfer between an iPad and a Mac.

Apple's Universal Clipboard mostly works. When it doesn't, it fails silently —
no error, no retry, no indication that the thing you copied never arrived.
ClipBridge makes that failure visible, makes it recoverable, and adds an SSH
fallback for when the network or the sharing daemon is the problem.

Copy on one device, paste on the other. The rest of this is for the times that
doesn't work.

---

## The problem

Copying doesn't move anything. It broadcasts that a clip *exists*; the bytes
travel later, when something actually reads the pasteboard — normally the
instant you press paste. That cold fetch is where the latency and the failures
live.

Two distinct things go wrong:

**Hollow clips.** Roughly **15% of clips sent from the iPad arrive empty** — an
announcement carrying a 5-byte type descriptor and no payload behind it. This
was measured over 35 occurrences, not estimated. The payload never exists and
never arrives late, so nothing on the Mac can recover it. Copying again on the
iPad is the only remedy.

**A silent daemon.** `sharingd`, the process behind Universal Clipboard, fails
in two different ways: *wedged* (announcements keep arriving, all of them
empty) and *silent* (nothing arrives at all). Neither surfaces anywhere in the
UI.

ClipBridge can't fix Apple's bug. What it can do is tell you the instant it
happens, keep a local copy of everything that did arrive, and give you a second
route that doesn't depend on Universal Clipboard at all.

---

## What it does

**Prefetches.** A background daemon polls the pasteboard every 0.35s and reads
any incoming payload immediately, rather than waiting for you to press paste.
By the time you paste, the data is already local. This has absorbed fetches as
slow as 3.5 seconds.

**Keeps history.** The last 300 text clips are stored on the Mac. When a clip
from the iPad goes missing, `clip last` usually has it — no need to touch the
iPad at all.

**Reports failures loudly.** A hollow clip raises a red banner with a sound the
moment it lands, so you find out immediately instead of after pasting nothing
into something important.

**Provides an SSH fallback.** Two iPad Shortcuts move the clipboard directly
over SSH, bypassing Universal Clipboard entirely. Text, images and web page
URLs all survive the trip.

**Watches the daemon.** A 60-second watchdog detects `sharingd` wedging and
restarts it.

---

## Requirements

- macOS 12 or later, and Xcode command line tools (`xcode-select --install`)
- Both devices signed into the same Apple ID, with Bluetooth and Wi-Fi on —
  Universal Clipboard uses Bluetooth LE plus AWDL, never your network, so the
  Wi-Fi radio must be on even if the Mac is on ethernet
- For the SSH fallback: Remote Login enabled on the Mac
  (`sudo systemsetup -setremotelogin on`), and an SSH client on the iPad
- Optional: [Tailscale](https://tailscale.com) on both devices, for networks
  that block device-to-device traffic

## Install

```sh
git clone https://github.com/huangsikai8/ClipBridge.git
cd ClipBridge
./install.sh
```

The clone can live anywhere. `install.sh` compiles the agent, signs it, loads
both launchd services, and links `clip` and `autopaste` into `~/.local/bin`.
Re-run it after changing anything in `src/`.

`./uninstall.sh` stops and removes everything. Clip history is left in place.

### A note on code signing

The prefetch agent ships as an `.app` bundle because auto-paste needs
Accessibility, which macOS grants to bundles rather than to bare executables.
That grant only *persists* if the app is signed with a stable identity —
ad-hoc signing produces no stable designated requirement, so macOS grants the
permission and then silently revokes it minutes later.

`install.sh` uses the first code-signing certificate in your login keychain. If
you have none, it warns you and falls back to ad-hoc. To make one: **Keychain
Access → Certificate Assistant → Create a Certificate**, any name, type *Code
Signing*. Then re-run `install.sh`. Override the choice with
`CLIPBRIDGE_SIGN_IDENTITY="Name" ./install.sh`.

---

## Usage

```
clip            state, which route works on this network, health
clip fix        full check, restart the sharing daemon, verify against the iPad
clip last       put the last clip back on the clipboard

autopaste up    auto-paste clips arriving from the iPad
autopaste down  stop that
```

Rarely needed: `clip test` (Tailscale route), `clip hist` (browse history),
`clip check` (full prerequisite check), `clip net`, `clip key`.

Everything else in `bin/` still runs directly; these are the names worth
remembering.

### When it fails

| Direction | Type | What to do |
| --- | --- | --- |
| Mac → iPad | text or image | run **Pull** on the iPad |
| iPad → Mac | text | `clip last` on the Mac, or run **Push** |
| iPad → Mac | image | run **Push** on the iPad |

`clip last` is usually fastest for iPad → Mac, since the clip is already stored
on the Mac.

If nothing works in either direction, run `clip fix`. It restarts the sharing
daemon, then waits 10 seconds for a real clip to prove the fix worked, naming
whichever side is still at fault if none arrives.

---

## Setting up the iPad Shortcuts

Both Shortcuts use a single **Run Script Over SSH** action.

Find your host and user with `clip` (or `clip net`), which prints the address
that works on your current network:

| Route | Host | Where it works |
| --- | --- | --- |
| Local | `your-mac.local` | most networks, including home |
| Tailscale | `your-mac.tailnet-name.ts.net` | anywhere, including networks that block peer traffic |

Tailscale must be running on **both** devices. One on and one off is the only
combination that fails silently.

Authorise the iPad's key once: copy the iPad's SSH public key, then run
`clip key` on the Mac.

**Push** — send the iPad's clipboard to the Mac:

| Action | Setting |
| --- | --- |
| Get Clipboard | |
| Base64 Encode | |
| Run Script Over SSH | Script: `~/Scripts/ClipBridge/bin/clip-recv --b64`<br>Input: the encoded variable |

**Pull** — fetch the Mac's clipboard onto the iPad:

| Action | Setting |
| --- | --- |
| Run Script Over SSH | Script: `~/Scripts/ClipBridge/bin/clip-send` |
| If | Output *contains* `__CLIPBRIDGE_PNG__` → strip the prefix, Base64 Decode, Set Clipboard |
| Otherwise | Set Clipboard to the output |

Two things reliably go wrong here:

- **The payload must go in the action's Input field, never in the script
  string.** SSH's exec limit is far below `ARG_MAX`, so anything beyond a short
  string fails with *"Unable to send channel request"*.
- **A Shortcuts variable typed as text looks identical to a real one** and
  fails silently. `clip-recv` logs every invocation and every failure to
  `bridge.log` precisely so this is visible.

Nothing needs a branch for images on the way *in* — `clip-recv` sniffs magic
bytes and decides for itself whether it received an image, a web page (reduced
to its URL) or plain text.

---

## Auto-paste

`autopaste up` makes clips arriving from the iPad paste themselves into
whatever window is focused, with a notification saying what landed.

Three guards, each added after a real failure: it ignores **re-announcements**
of a clip already pasted (the iPad re-advertises repeatedly — without this it
pasted the same image five times), **echoes** of clips copied on this Mac
(without this it pasted your own clipboard back at you), and **hollow** clips,
which raise the red banner instead. Anything a password manager marked
concealed is never touched.

> **It pastes wherever focus happens to be, and you will not always be
> watching. Multi-line text landing in a terminal can execute.** That risk is
> inherent to the feature, not a bug. `autopaste down` is instant.

Requires Accessibility, granted to `ClipBridgeAgent.app` in **System Settings →
Privacy & Security**.

---

## Why the two directions behave differently

They're asymmetric, and always will be.

**iPad → Mac** can be fixed, because the Mac can run a daemon at copy time.
That's the prefetching, the history, the failure banners.

**Mac → iPad** cannot. iOS runs no third-party code when you copy, and
Shortcuts has no clipboard trigger, so that direction is exactly Apple's stock
behaviour — no early fetch, no history, nothing to recover from. Pull is the
remedy there.

This also means there is **no observability into Mac → iPad at all.** The only
evidence it works is the occasional echo coming back: 5 out of 1011 local
copies. A clean `clip` report does not prove the clipboard is working — every
external check can pass while nothing moves.

---

## Layout

```
bin/            all commands; clip dispatches to the rest
src/            Swift sources — prefetch daemon, image read/write
launchagents/   launchd service templates
install.sh      build, sign, load
uninstall.sh    stop and remove
CLAUDE.md       architecture, traps and measured findings
```

Runtime data lives in `~/Library/Application Support/ClipBridge/`:

- `prefetch.log` — every pasteboard change, the primary evidence source
- `bridge.log` — every SSH transfer, with size, kind and the route it took
- `history/` — the last 300 text clips, backing `clip last`

Between those two logs, most questions about what actually happened have an
answer.

---

## Things worth knowing if you fork this

- `pbcopy` / `pbpaste` are **text-only**. Images need `NSPasteboard`, which is
  what `clip-image` and `clip-setimage` are for.
- `public.plain-text` is a **different UTI** from `.string`
  (`public.utf8-plain-text`). Reading the wrong one makes a full clipboard look
  empty.
- macOS ships **bash 3.2** — no `mapfile`, no `etimes` in `ps`.
- macOS **redacts the Wi-Fi SSID** without location permission, so networks are
  identified by gateway MAC instead.
- `grep -q` in a pipeline under `set -o pipefail` **inverts checks**: grep exits
  early, SIGPIPE kills the upstream command, and the pipeline reports failure.

## Limitations

- Hollow clips are unfixable from the Mac. Copy again.
- Mac → iPad reliability is unmeasured, and probably unmeasurable from here.
- Retry on hollow clips was implemented and then removed: 0 recoveries in 9
  attempts, and the wait blinded the polling loop for 7 seconds each time.
- Keep-warm — periodically rewriting the pasteboard to keep the link alive —
  was built, measured and disabled. The data refuted the theory behind it, and
  it cleared the pasteboard before rewriting, opening a window in which the
  iPad could fetch nothing.
