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

## Files

- `index.html`: the whole app.
- `Niepotrzebne/`: dev server and measurement scripts that drive the page in a real Chrome over CDP.
