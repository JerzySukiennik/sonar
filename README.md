# Sonar

An acoustic echogram in one HTML file. The laptop speaker plays short chirps, the microphone records them, and pulse compression turns every echo into a distance.

## Run

Open `index.html` in Chrome, press Start and allow the microphone. Use the built-in speakers (headphones give no echo path).

## How it works

- A 43 ms linear chirp repeats every 8192 samples (about 6 pings per second at 48 kHz). It plays on the left channel only, so there is one sound source.
- An AudioWorklet plays and records in the same sample clock, so the delay between output and input stays constant.
- Each recorded period is deconvolved with the chirp (Wiener filter, Hann window over the band). The result is the room impulse response.
- The strongest peak is the direct speaker to microphone path and becomes zero distance. Everything after it is an echo at `lag * 343 / (2 * sampleRate)` metres.
- Everything view: short coherent average of the impulse response. Motion view: the response minus a slow background, so only changes show.
- Range gain (`20 log r`) keeps far echoes visible. Pings hit by a loud noise burst are dropped. The volume drops by itself when the microphone gets close to clipping.

## Bands

| Band | Range | Resolution |
|---|---|---|
| Wide | 2 to 20 kHz | 1.9 cm |
| High | 10 to 21 kHz | 3.1 cm |
| Quiet | 17 to 22 kHz | 6.9 cm |

## Measured on a MacBook Pro 16" 2019

- Round trip latency in Chrome is about 105 ms and stable to 0.02 samples over 14 s.
- The built-in microphone exposes one channel, so this gives distance only, no direction.
- Too loud is worse than too quiet: when the microphone peak passes about 1.0 the noise floor rises from -56 dB to -40 dB relative to the direct path.
- Echoes out to about 4 m stand 15 to 20 dB above the floor.

## iPhone: rough 3D map (`iOS/`)

A native app that tries to find the flat surfaces of a room from the same echoes. Status: runs on an iPhone XR. On a real 15 second scan it finds the floor 1.41 m below the phone and the ceiling 1.42 m above it. Walls are not confirmed yet.

- The phone plays 2 to 15 kHz chirps about 12 times a second and records with its own microphone.
- ARKit gives the phone pose for every ping. One microphone only knows distance, so direction comes from moving the phone.
- Time zero is the first arrival of the phone's own sound. The iPhone has two speakers 14 cm apart, so the loudest arrival is not stable.
- Walls reflect like mirrors: a wall at distance `d` along normal `n` is heard at range `d - n.p` from position `p`. Every ping votes for all `(n, d)` that explain its echoes (800 directions, 2.5 cm steps). A real wall collects votes from every position. Echoes at a fixed range, like the hand and body of the person holding the phone, smear out instead.
- Peaks are merged with their neighbours, snapped to horizontal or vertical (rooms follow gravity, and ARKit knows which way is up), and slanted candidates are dropped as artefacts.
- Nothing is shown until the phone has moved enough in all three axes (about 15 cm each way), because before that every direction fits equally well. The first version painted spheres into a voxel grid and with little movement the result was a ball around the phone.
- Start resumes the same map, Clear starts over. Every session is saved to `Documents/scan-<date>.sonarlog` (raw audio and poses, last five kept) for offline tuning.

Build with `Scripts/ios.sh`: `mac` (Catalyst build for checks), `device` (sign and install, works over Wi-Fi once the phone is paired), `log` (pull the last session from the phone). Needs XcodeGen.

Checks without a phone, on the Catalyst build:

- `Sonar --dsp`: synthetic frames through the pulse compressor, prints the measured lag and echo range.
- `Sonar --demo --shot out.png`: a synthetic room with fixed-range clutter through the plane finder and the renderer.
- `Sonar --replay scan.sonarlog --shot out.png`: a real recording from the phone through the same code. Add `--first-chirp` for logs recorded with the first chirp (1024 samples, 3 to 18 kHz).
- `Niepotrzebne/analyze.py scan.sonarlog`: levels, timing and echo table of a recording.

## Files

- `index.html`: the browser echogram.
- `iOS/`: the iPhone app (Swift, SceneKit, ARKit).
- `Scripts/ios.sh`: build and install.
- `Niepotrzebne/`: dev server, icon generator and measurement scripts that drive the page in a real Chrome over CDP.
