# Sign

An iPhone and iPad app that listens to music and fingerspells the words being sung in the ASL manual alphabet.

- The screen is a mosaic of hexagons that fit together perfectly. A hand is drawn by lighting up those tiles.
- The hand is a small 3D skeleton (palm, thumb, and three joints per finger) posed for each of the 26 letters. J and Z trace their motion, and doubled letters slide sideways as signers show them.
- Its colours come from the music:
  - the harmony sets the hue
  - the beat sends light up the hand
  - the bass lights the palm
  - the snare flashes the fingertips
  - the hats make the tiles glitter
- The words are picked out of the audio with Apple's speech recognizer, on the device where it can be. Fast singing outruns spelling, so it keeps to the newest words.

Fingerspelling only: whole-word ASL signs depend on motion, location and facial grammar, and are not attempted.

Sign was lifted out of Felt, a music-to-vibration-and-light app; this repository keeps only the Sign picture and the listening engine behind it (audio analysis, note reading, haptics, the Apple Watch companion and the screen-broadcast extension).

## Build

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Felt.xcodeproj
```

Set your own development team and bundle identifiers in `project.yml` before running on a device.

For testing without a singer, set `FELT_SIGN_WORDS="some words"` in the scheme's environment to spell those words in turn.
