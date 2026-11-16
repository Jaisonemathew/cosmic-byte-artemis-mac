# Cosmic Byte Artemis lighting for macOS

Control the RGB lighting of a **Cosmic Byte Artemis** mechanical keyboard from a Mac, with no Windows and no drivers.

Cosmic Byte's lighting software only runs on Windows. This project talks to the keyboard directly over USB HID, using the protocol worked out from the official Windows app.

- **`artemis-rgb`**: a command-line tool
- **Artemis RGB.app**: a menu bar app with presets, a custom colour picker, effect, brightness, speed and direction controls

Tested with a 68-key Artemis (USB ID `04D9:A1CE`, Holtek controller).

## Build

You need the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

```bash
./build.sh
```

This produces `build/artemis-rgb` and `build/Artemis RGB.app`. Copy the app to `~/Applications` and the CLI anywhere on your `PATH`.

## Command line

```bash
artemis-rgb status                                   # current effect, brightness, palette
artemis-rgb color ff8800                             # static orange
artemis-rgb color purple --effect breathing --brightness 3 --speed 2
artemis-rgb color rainbow --effect wave --direction left
artemis-rgb effects                                  # list effects
```

Effects: static, breathing, wave, induction-darken, marquee, ripple, induction-brighten, neon, marquee-colorful, raining, marquee-circle, spotlight.

Settings are stored on the keyboard itself, so they persist after unplugging and work on any computer.

## Menu bar app

Click the keyboard icon in the menu bar. **🎲 Random** picks a vivid colour at least 60° around the colour wheel from the current one. Unplugging and replugging the keyboard is picked up automatically. Changes apply about a third of a second after you stop adjusting a control, so dragging doesn't flood the keyboard's onboard memory with writes. When it opens, the panel reads the keyboard's current settings.

## Protocol

The keyboard exposes a vendor HID interface (usage page `0xFF01`). Commands are 8-byte **feature reports** (report ID 0). Bulk data follows as 64-byte **output reports**.

| Command | Bytes | Purpose |
|---|---|---|
| `0x08` | `08 type brightness speed direction colour bl0 bl1` | Set lighting effect |
| `0x88` | `88 00 00 00 00 55 AA 00`, then get feature → 8 bytes | Read lighting effect |
| `0x30` | `30 00 00 00 00 55 AA 00`, then 64-byte output report | Set 7-colour palette |
| `0xB0` | `B0 00 00 00 00 55 AA 00`, then 64-byte input report | Read palette |

- **type**: 0 static, 1 breathing, 2 wave, 3 induction darken, 4 marquee, 5 ripple, 6 induction brighten, 7 neon, 8 marquee colourful, 9 raining, 10 marquee circle, 11 spotlight
- **brightness**: 0–63 · **speed**: 1 (fastest)–5 · **direction**: 0 right, 1 left
- **colour**: palette slot 0–6, or 7 for rainbow. Palette entries are 7 × RGB with **6-bit** channels (0–63).
- **bl0, bl1**: preserved from the read-back value.

⚠️ The firmware also has an ISP bootloader command (`0x0F`) and a recovery command (`0x13`). This code never sends them, and asserts against them.

## Disclaimer

Unofficial and not affiliated with Cosmic Byte. Use at your own risk.
