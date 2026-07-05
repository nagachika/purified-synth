# Modular Synthesizer Architecture

This document defines the node architecture and the JSON schema used to construct the synthesizer patch.

## JSON Patch Schema

The `Synthesizer` and `Voice` classes expect a patch definition in the following JSON format:

```json
{
  "nodes": [
    {
      "id": "unique_string_id",
      "type": "NodeType",
      "params": {
        "param_name": "value"
      },
      "freq_track": boolean  // Optional: If true, this node's frequency tracks the note pitch (for Oscillators)
    }
  ],
  "connections": [
    {
      "from": "source_node_id",
      "to": "target_node_id"       // Connect to the node's main input
    },
    {
      "from": "source_node_id",
      "to": "target_node_id.param" // Connect to a specific parameter
    }
  ]
}
```

### Special Connection Targets
- `"out"`: connecting to `"to": "out"` routes the signal to the Voice's main output (usually triggering the ADSR release phase properly).

## Available Nodes

### Source Nodes

#### `Oscillator`
Standard periodic waveform generator.
- **Init Params:**
  - `type`: `"sine"`, `"square"`, `"sawtooth"`, `"triangle"`
  - `frequency`: Base frequency (Hz). Ignored if `freq_track: true`.
- **Audio Params (Inputs):**
  - `frequency`: Modulation of frequency (Hz).
  - `detune`: Detuning in cents.

#### `Noise`
White noise generator.
- **Init Params:** None.
- **Audio Params (Inputs):** None.

#### `Constant`
Outputs a constant DC value. Useful for control signals or offsets.
- **Init Params:**
  - `offset`: The constant value.
- **Audio Params (Inputs):**
  - `offset`: Modulate the constant value.

### Processor Nodes

#### `BiquadFilter`
Standard multi-mode filter.
- **Init Params:**
  - `type`: `"lowpass"`, `"highpass"`, `"bandpass"`, `"notch"`, `"peaking"`, `"allpass"`, `"lowshelf"`, `"highshelf"`
  - `frequency`: Cutoff frequency (Hz).
  - `q`: Q factor / Resonance.
- **Audio Params (Inputs):**
  - `frequency`: Cutoff modulation.
  - `detune`: Cutoff detuning.
  - `Q`: Resonance modulation.
  - `gain`: Gain (used for peaking/shelf filters).

#### `CombFilter`
A custom filter utilizing delay and feedback.
- **Init Params:**
  - `frequency`: Frequency of the comb notches (Hz).
  - `q`: Feedback amount (0.0 to ~0.95).
- **Audio Params (Inputs):**
  - `frequency`: Modulates delay time (inverse of frequency).
  - `q` / `resonance`: Modulates feedback gain.

#### `Gain`
Amplifies or attenuates the signal.
- **Init Params:**
  - `gain`: Initial gain value (default 1.0).
- **Audio Params (Inputs):**
  - `gain`: Amplitude modulation (AM).

#### `ADSR`
Envelope generator. Note: In this architecture, ADSR is treated as a signal source that outputs 0->1->0 values, usually connected to a `Gain` node's gain parameter.
- **Init Params:**
  - `attack`: Time in seconds.
  - `decay`: Time in seconds.
  - `sustain`: Level (0.0 - 1.0).
  - `release`: Time in seconds.
- **Audio Params (Inputs):** None.

### Effect Nodes (synth-shared)

Unlike every other node type, effect nodes are instantiated **once per Synthesizer** and shared by all voices, instead of being rebuilt for each `note_on`. All sounding voices are mixed into the same effect instance (equivalent for these linear effects), which keeps CPU cost constant under polyphony and lets delay/reverb tails keep ringing after a voice is torn down.

Consequences:
- An effect node's **output may only connect to another effect node or `"out"`**. The graph editor rejects other connections; Ruby skips them with a warning.
- Per-voice sources (LFOs, envelopes) *may* modulate an effect node's params, but the modulation signals from all voices **sum** on the shared parameter.
- Parameter edits apply live to the shared instance without cutting tails; adding/removing effect nodes or rewiring them rebuilds the shared section.

#### `DelayEffect`
Feedback delay with wet/dry mix.
- **Init Params:**
  - `delay_time`: Delay time in seconds (0.0 - 5.0).
  - `feedback`: Feedback gain (0.0 - 0.95).
  - `mix`: Wet/dry balance (0.0 - 1.0).
- **Audio Params (Inputs):**
  - `delay_time`: Modulates delay time.
  - `feedback`: Modulates feedback gain.
  - `mix`: Modulates the wet gain (dry stays at its static `1 - mix`).

#### `ReverbEffect`
Convolution reverb with a procedurally generated impulse response.
- **Init Params:**
  - `seconds`: Decay length in seconds (0.1 - 5.0). Rebuilds the impulse response (cached per length), so it is an init param only.
  - `mix`: Wet/dry balance (0.0 - 1.0).
- **Audio Params (Inputs):**
  - `mix`: Modulates the wet gain (dry stays at its static `1 - mix`).

## Voice Pooling (sequencer path)

Notes played through `Synthesizer#schedule_note` (sequencer playback, drum machine, chord audition) can reuse a pool of persistent voices instead of building a fresh Web Audio graph per note. Web Audio source nodes are one-shot (no restart after `stop()`), so pooled voices start their sources once and are gated purely by the envelope-driven VCA; note-on retunes the pitch params and retriggers the envelopes. The interactive `note_on`/`note_off` path always uses dynamically created voices.

Enable/disable at runtime with `Synthesizer.voice_pooling = true/false` (class flag in `src/synthesizer.rb`, default `false`). Pools are per-Synthesizer, grown on demand, and torn down whenever the patch changes (`custom_patch=`) or the synth closes.

### Tuning constants

A pooled voice occupies its pool entry for `hold + release + SETTLE_SLACK` per note, where `hold` is the audible note length. All trade-offs between pool size (idle voices burn audio-thread CPU even when silent) and reuse artifacts are controlled by these constants:

- **`VoicePool::MAX_VOICES`** (`src/synthesizer/voice_pool.rb`) — per-Synthesizer voice cap. When the pool is full, the voice deepest into its release is *stolen* (its tail is faded out over `RETRIGGER_FADE` and the voice is retriggered); voices still holding their note are never stolen — those notes fall back to a dynamically built voice. Raising the cap lowers the steal rate at the cost of more idle voices (measured demand in the bundled stress scene: ~23 voices per dense chord track).
- **`VoicePool::SETTLE_SLACK`** (`src/synthesizer/voice_pool.rb`) — extra wait after one release time-constant before an entry counts as free *without* stealing. At reuse time the residual tail is ~5% of peak; lengthening this trades pool size for quieter (steal-free) reuse.
- **`ADSREnvelope::RETRIGGER_FADE`** (`src/synthesizer/adsr_envelope.rb`) — the few milliseconds over which `trigger` fades any still-sounding residual to the floor before starting the attack. This is what makes reuse/stealing click-free; it also delays every attack uniformly by the same amount.
- **Hold shortening** — `Voice#audible_hold` (`src/synthesizer/voice.rb`) cuts a note's hold time to `attack + decay` when every envelope has zero sustain (e.g. drum patches go silent long before their nominal duration), freeing the voice much earlier. The `0.001` sustain threshold lives there.

The measurement harness for re-tuning these lives in `window.__seqMetrics` (`src/js/main.js`) plus `Sequencer#metrics_json` / `#reset_metrics`; `example/stress_scene.json` reproduces the dense scene used for tuning (late-schedule count, steal/overflow counters, tick timings).