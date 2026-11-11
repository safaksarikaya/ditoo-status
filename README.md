# Ditoo Status

A macOS menu bar app that turns a **Divoom Ditoo Plus** (16×16 pixel screen) into a desk status screen:

- **Rotation:** clock → your own image or GIF (the Divoom app's design channel) → agents.
  An agent is shown only while it works or waits for you.
- **AI agents:** Claude Code sessions are shown through its hooks. Any other agent or script can report its
  state with one command and bring its own GIFs. When an agent waits for you, it interrupts the rotation and
  stays up until you answer.
- **Battery alerts** for Bluetooth mice and keyboards, plus charging and full screens.
- **Key lights** follow the state (idle, working, waiting, low battery, charging).
- **Auto-reconnect** after the Ditoo is switched off and on.
- A small **drawing editor** for a home screen of your own.

It talks to the Ditoo directly over Bluetooth Classic (RFCOMM). No Divoom cloud or phone is needed after
pairing.

## Requirements

- macOS 14 or later.
- A Ditoo Plus paired in System Settings → Bluetooth. Pick the `…-audio` entry; the screen is reached over
  the same connection.
- The Swift toolchain: Xcode, or `xcode-select --install`.

## Build and install

```sh
cd app
./build.sh            # builds app/build/Ditoo Status.app
./build.sh --install  # also copies it to ~/Applications and restarts it
```

On first launch macOS asks for Bluetooth access. Then turn on **Open at login** in Settings.

**Signing.** macOS remembers the Bluetooth permission per signing identity. `build.sh` uses `$SIGN_ID` if
set; otherwise it uses your first "Apple Development" certificate, if you have one. Xcode → Settings →
Accounts creates one for free. Without a certificate the app is ad-hoc signed and works the same, but macOS
asks for Bluetooth again after every rebuild.

## Claude Code

In Settings → Claude Code, click **Install hooks**. This adds entries to `~/.claude/settings.json`, and a
backup is kept next to it. The hooks only write each session's state to a local file. They don't call the
model and cost no tokens. If you move the app, the hooks are updated on its next launch.

The mascot walks while Claude works and jumps while Claude waits for you. One dot per session appears on
the right, up to four.

## Other agents

```sh
~/"Library/Application Support/DitooStatus/ditoo-agent" <agent> <working|waiting|done|end> [session]
```

Each agent's visuals go in `~/Library/Application Support/DitooStatus/agents/<agent>/`:
`working.gif`, `waiting.gif`, `done.gif` and/or `default.gif`. PNG, WebP and JPEG also work, at any size;
images are scaled to 16×16.

An optional `agent.json` sets the display name, the session dots and per-state key-light effects:

```json
{ "name": "Codex", "dots": true, "keys": { "working": 8, "waiting": 2 } }
```

The folder's `README.txt` has the details. Claude's own mascot is exported there as editable GIFs.
**Restore Claude's visuals** in Settings brings back the originals.

## Development

The app listens on `127.0.0.1:40404` (local only) for one command per line:

```sh
app/dev/ditoo status
app/dev/ditoo send 23 01          # raw payload; framing and checksum are added
app/dev/ditoo show clock|home|claude|agent <name>|charging|battery
app/dev/ditoo agent test waiting  # fake an agent state
app/dev/ditoo keys [at <n>|prev|next]
app/dev/ditoo login on|off
app/dev/ditoo reload
```

The log is in `~/Library/Logs/DitooStatus.log`.

### Protocol notes

Frames are `01 LEN(2, LE) payload CHECKSUM(2, LE) 02`. The checksum is the byte sum of the length and the
payload.

The key lights on stock firmware only understand `23 00` (previous effect), `23 01` (next) and `23 02`
(on/off). The current effect can't be read back. So the app counts steps from solid white (effect 0);
`Sources/Keys.swift` lists the effects seen.

## Credits

- **Clawd**, the Claude Code mascot drawn here in pixels, is Anthropic's character. This project is not
  affiliated with or endorsed by Anthropic.
- Divoom and Ditoo are trademarks of Divoom. This project is not affiliated with Divoom.
- The protocol comes from community reverse engineering. This project reimplements it in Swift; no code
  from these projects is included.
  - [hass-divoom](https://github.com/d03n3rfr1tz3/hass-divoom) by d03n3rfr1tz3: framing, image and
    animation upload, channels, clock, brightness and the Ditoo key-light command.
  - [node-divoom-timebox-evo](https://github.com/RomRider/node-divoom-timebox-evo) by RomRider: the
    image encoding (palette plus packed pixel bits).
  - [ditoo-pro-custom-firmware](https://github.com/mert4x4/ditoo-pro-custom-firmware) by mert4x4,
    [divoom-ditoo-pro-controller](https://github.com/futpib/divoom-ditoo-pro-controller) by futpib and
    [pixelbox](https://github.com/dend/pixelbox) by dend: command catalogues used to check what the
    key lights support.

## License

MIT. See [LICENSE](LICENSE). The Clawd character is not covered by this license; it belongs to Anthropic.
