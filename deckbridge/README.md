# Deck Bridge: Cratebox as a touch controller for rekordbox

Deck Bridge (the mode selector → **Deck Bridge**) turns the phone or iPad into a controller for rekordbox's
decks 3 and 4 (or 1 and 2): jog wheels, PLAY / CUE, sync, key lock, quantize, slip, 8 hot cue pads (SHIFT
deletes), loops, tempo, trim, 3-band EQ, filter, channel faders, headphone cue, crossfader, Beat FX, browse and
load. rekordbox lights the buttons back (PLAY, CUE, SYNC, loops, hot cues).

No desktop companion app is needed: the link is standard MIDI.

## 1. Link the phone to the computer

| Computer | How |
| --- | --- |
| Mac, Wi-Fi | Audio MIDI Setup → Window → Show MIDI Studio → the globe (Network). Under **Directory** pick the phone, press **Connect**. |
| Mac, cable | Plug the phone in. In Audio MIDI Setup → Window → Show Audio Devices, click **Enable** under the iPhone/iPad. |
| Mac, Bluetooth | Deck Bridge → ⚙ → Bluetooth MIDI… (the phone advertises). Audio MIDI Setup → MIDI Studio → Bluetooth → Connect. |
| Windows | Install **rtpMIDI** (free, Tobias Erichsen). Add the phone under Directory, press Connect. |

Same Wi-Fi for both; a phone hotspot or a direct cable is steadier than a busy venue network.

## 2. Import the mapping in rekordbox (once)

rekordbox (Performance mode) → **MIDI** (top right) → pick the device (the network session, IDAM or Bluetooth
port) → **IMPORT** → `Cratebox Deck Bridge.midi.csv` (this folder, or Deck Bridge → ⚙ → Share).

The file follows the layout of Pioneer's own 4-deck mapping files (deck N on MIDI channel N, pads on channels
8–11, mixer globals on 7, Beat FX on 5, 14-bit faders, relative jogs centred on 64).

## What isn't verified yet

These files were built from rekordbox's own shipped mappings, not tested against a running rekordbox in this
build. Most likely to need a manual **MIDI LEARN** (Deck Bridge → ⚙ → Learn helper sends any control on demand):

- **Jog wheels**: Pioneer's own files leave the jog rows to their hardware drivers; rekordbox may not accept
  `JogRotate` rows for a generic device.
- **Hot cue pads** (`Pad` rows) may need the deck in HOT CUE pad mode first (the **MODE** link above the pads).
- The **tempo** direction: Deck Bridge sends "up = slower" like a CDJ; flip it in ⚙ if rekordbox disagrees.

Please report which rows rekordbox took and which needed learning, so the file can be fixed.
