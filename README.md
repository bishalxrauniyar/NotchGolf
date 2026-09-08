# ⛳ NotchGolf

A tiny 9-hole mini-golf game that lives in your MacBook's notch — for the moments your AI is busy writing code.

![NotchGolf](.github/social.png)

## Play

- **Grab the ball, drag back, release to putt** — the aim line sweeps green → red with power
- Sink it and a score banner drops: ACE / EAGLE / BIRDIE / PAR / BOGEY
- Endless holes — they get harder: more bunkers, water carries, bumpers
- **Total** keeps your running score vs par; **Best** is your lowest round ever
- Land in water → splash, ball returns to where you shot from

## Controls

| Action | Input |
|---|---|
| Show / hide game | `⌃⌥G` (Ctrl+Option+G) |
| Putt | drag from ball, release |
| Menu | ⛳ in the menu bar |

## Build

```sh
./build.sh
open NotchGolf.app
```

Everything is procedural — graphics, icon, audio (synthesized putt/wall/sand/sink/splash sounds) — zero asset files. The built app is ~200 KB.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)

## License

MIT
