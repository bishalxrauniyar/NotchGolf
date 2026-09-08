# ⛳ NotchGolf

A mini-golf game that floats over your entire macOS desktop — for the moments your AI is busy writing code.

The ball, cup, flag, sand traps, water hazards and bumpers are drawn directly over your screen. Everything else is click-through, so your Mac works exactly as usual while you play.

![NotchGolf](.github/social.png)

## Play

- **Grab the white ball, pull back, release to putt** — the aim line sweeps green → red with power
- The cup moves to a new spot every hole — putting across your whole desktop (or displays)
- Sink it: ACE / EAGLE / BIRDIE / PAR / BOGEY banners drop mid-screen
- Sand slows the ball, water resets it to where you shot from (+0 strokes), bumpers kick it away
- **Total** keeps your running score vs par; **Best** is your lowest hole ever
- Endless holes that get harder: more hazards, bigger pars

## Setup

### Install (easiest)

1. Download the latest zip from [Releases](https://github.com/bishalxrauniyar/NotchGolf/releases)
2. Unzip and drag **NotchGolf.app** to **Applications**
3. Open it. Unsigned build — if Gatekeeper complains: right-click the app → **Open** → Open
4. The ball appears on your desktop. That's it.

### Build from source

```sh
git clone https://github.com/bishalxrauniyar/NotchGolf.git
cd NotchGolf
./build.sh
open NotchGolf.app
```

Requirements: macOS 14+ and Xcode Command Line Tools (`xcode-select --install`).

Everything is procedural — graphics, icon, audio (synthesized putt/wall/sand/sink/splash sounds) — zero asset files. The built app is ~200 KB.

## Controls

| Action | Input |
|---|---|
| Putt | drag from the ball, release |
| Show / hide | `⌃⌥G` (Ctrl+Option+G) |
| Menu (sound, restart, quit) | ⛳ in the menu bar |

## Notes

- Works across multiple extended displays — the course spans the union of all screens
- Only the area right around the ball (~72px) is interactive; every other click passes through to the app below
- Idles at 0 CPU when you're not playing

## License

MIT
