#!/usr/bin/env ruby
# Generate Pachelbel's Canon (first 16 measures) as ruby-wasm-purified-synth project JSON
# CORRECTED version: 2 chords per measure, proper inversions per PDF score

require 'json'
require 'time'

# ---- JI lattice base coordinates (relative to D root) ----
# D4 = (0,0,0) = root_freq = 260Hz
# Each note base: {a_base, b, c} where a gets octave offset added
#
# Formula: freq = 260.0 * (2.0 ** a) * (1.5 ** b) * (1.25 ** c)
#
# Convention: D4=260Hz. Each octave change -> a +/- 1.
# a_base places the note in its "native octave" (see NATIVE_OCT).
# For other octaves: a = a_base + (oct - native_oct)

NOTE_BASE = {
  #           a   b   c    ratio    freq@native_oct
  "D"  => { a:  0, b:  0, c: 0 }, # 1/1    = 260.00 Hz (D4)
  "E"  => { a: -1, b:  2, c: 0 }, # 9/8    = 292.50 Hz (E4)
  "F#" => { a:  0, b:  0, c: 1 }, # 5/4    = 325.00 Hz (F#4)
  "G"  => { a:  1, b: -1, c: 0 }, # 4/3    = 346.67 Hz (G4)
  "A"  => { a:  0, b:  1, c: 0 }, # 3/2    = 390.00 Hz (A4)
  "B"  => { a:  1, b: -1, c: 1 }, # 5/3    = 433.33 Hz (B4)
  "C#" => { a: -1, b:  1, c: 1 }, # 15/8   = 243.75 Hz (C#4, just below D4)
}

NATIVE_OCT = {
  "D" => 3, "E" => 3, "F#" => 3, "G" => 3, "A" => 3, "B" => 3, "C#" => 3,
}

# Build NoteCoord {a, b, c, d, e} for note_name + octave
def n(note, dim=3)
  note_name = note[0...-1]
  oct = note[-1].to_i
  base = NOTE_BASE[note_name] or raise "Unknown note: #{note}: #{note_name}:#{oct}"
  a = base[:a] + (oct - NATIVE_OCT[note_name])
  case dim
  when 3
    { a: a, b: base[:b], c: base[:c], d: 0, e: 0 }
  when 4
    { a: a, b: base[:b], c: 0, d: base[:c], e: 0 }
  when 5
    { a: a-(base[:c]>0 ? 1 : 0), b: base[:b], c: 0, d: 0, e: base[:c] }
  end
end

# Calculate frequency from coord (for verification)
def freq(coord)
  260.0 / 2.0 * (2.0 ** coord[:a]) * (1.5 ** coord[:b]) * (1.25 ** coord[:c])
end

# ---- Frequency assertions ----
def assert_freq(note, expected)
  c = n(note)
  f = freq(c)
  unless (f - expected).abs < 0.01
    raise "FAIL: #{note} = #{f}, expected #{expected}, coord=#{c}"
  end
end

assert_freq("D4", 260.00)
assert_freq("D3", 130.00)
assert_freq("D2",  65.00)
assert_freq("D5", 520.00)
assert_freq("E4", 292.50)
assert_freq("E3", 146.25)
assert_freq("F#4", 325.00)
assert_freq("F#3", 162.50)
assert_freq("F#2",  81.25)
assert_freq("G4", 346.667)
assert_freq("G3", 173.333)
assert_freq("G2",  86.667)
assert_freq("A4", 390.00)
assert_freq("A3", 195.00)
assert_freq("A2",  97.50)
assert_freq("B4", 433.333)
assert_freq("B3", 216.667)
assert_freq("B2", 108.333)
assert_freq("C#5", 487.50)
assert_freq("C#4", 243.75)
assert_freq("C#3", 121.875)

# ---- Step constants ----
STEPS_PER_MEASURE = 32  # 4/4 time, 1 step = 1/32 note
HALF    = 16  # 2分音符
QUARTER =  8  # 4分音符
EIGHTH  =  4  # 8分音符
TOTAL_MEASURES = 16
TOTAL_STEPS = TOTAL_MEASURES * STEPS_PER_MEASURE  # 512

# =========================================================
# SCORE DATA (from PDF reading + standard Canon supplement)
# =========================================================

# 8-chord progression per 4 measures (2 chords per measure):
# M1: D -> A
# M2: Bm -> F#m
# M3: G -> D
# M4: G -> A
# (repeat for M5-8, M9-12, M13-16)

# --- RIGHT HAND: Chord voicings (M1-8, from PDF) ---
# Voice-leading: top voice = Canon theme descending: F#4->E4->D4->C#4->B3->A3->B3->C#4
# Each chord is [bottom, middle, top] (low to high)
RH = [
  # measure 1-4
  { duration: 8, note: ["A3",  "D4",  "F#4"]},
  { duration: 8, note: ["A3",  "C#4", "E4"]},
  { duration: 8, note: ["F#3", "B3",  "D4"]},
  { duration: 8, note: ["F#3", "A3",  "C#4"]},
  { duration: 8, note: ["D3",  "G3",  "B3"]},
  { duration: 8, note: ["D3",  "F#3", "A3"]},
  { duration: 8, note: ["D3",  "G3",  "B3"]},
  { duration: 8, note: ["E3",  "A3",  "C#4"]},
  # measure 5-8
  { duration: 8, note: ["F#3", "A3",  "D4"]},
  { duration: 8, note: ["E3",  "A3",  "C#4"]},
  { duration: 8, note: ["D3",  "F#3", "B3"]},
  { duration: 8, note: ["C#3", "F#3", "A3"]},
  { duration: 8, note: ["B2",  "D3",  "G3"]},
  { duration: 8, note: ["A2",  "D3",  "F#3"]},
  { duration: 8, note: ["B2",  "D3",  "G3"]},
  { duration: 8, note: ["C#3", "E3"]},
  # measure 9-12
  { duration: 4, note: ["D3"]},
  { duration: 4, note: ["F#3"]},
  { duration: 4, note: ["A3"]},
  { duration: 4, note: ["G3"]},
  { duration: 4, note: ["F#3"]},
  { duration: 4, note: ["D3"]},
  { duration: 4, note: ["F#3"]},
  { duration: 4, note: ["E3"]},
  { duration: 4, note: ["D3"]},
  { duration: 4, note: ["B2"]},
  { duration: 4, note: ["D3"]},
  { duration: 4, note: ["A3"]},
  { duration: 4, note: ["G3"]},
  { duration: 4, note: ["B3"]},
  { duration: 4, note: ["A3"]},
  { duration: 4, note: ["G3"]},
  # measure 13-16
  { duration: 4, note: ["F#3"]},
  { duration: 4, note: ["D3"]},
  { duration: 4, note: ["E3"]},
  { duration: 4, note: ["C#4"]},
  { duration: 4, note: ["D4"]},
  { duration: 4, note: ["F#4"]},
  { duration: 4, note: ["A4"]},
  { duration: 4, note: ["A3"]},
  { duration: 4, note: ["B3"]},
  { duration: 4, note: ["G3"]},
  { duration: 4, note: ["A3"]},
  { duration: 4, note: ["F#3"]},
  { duration: 4, note: ["D3"]},
  { duration: 4, note: ["D4"]},
  { duration: 6, note: ["D4"]},
  { duration: 2, note: ["C#4"]},
  # measure 17-20
  { duration: 2, note: ["F#3", "D4"]},
  { duration: 2, note: ["C#4"]},
  { duration: 2, note: ["D4"]},
  { duration: 2, note: ["D3"]},
  { duration: 2, note: ["C#3"]},
  { duration: 2, note: ["A3"]},
  { duration: 2, note: ["E3"]},
  { duration: 2, note: ["F#3"]},
  { duration: 2, note: ["D3"]},
  { duration: 2, note: ["D4"]},
  { duration: 2, note: ["C#4"]},
  { duration: 2, note: ["B3"]},
  { duration: 2, note: ["C#4"]},
  { duration: 2, note: ["F#4"]},
  { duration: 2, note: ["A4"]},
  { duration: 2, note: ["B4"]},
  { duration: 2, note: ["B3", "G4"]},
  { duration: 2, note: ["F#4"]},
  { duration: 2, note: ["E4"]},
  { duration: 2, note: ["G4"]},
  { duration: 2, note: ["F#4"]},
  { duration: 2, note: ["E4"]},
  { duration: 2, note: ["D4"]},
  { duration: 2, note: ["C#4"]},
  { duration: 2, note: ["B3"]},
  { duration: 2, note: ["A3"]},
  { duration: 2, note: ["G3"]},
  { duration: 2, note: ["F#3"]},
  { duration: 2, note: ["E3"]},
  { duration: 2, note: ["G3"]},
  { duration: 2, note: ["F#3"]},
  { duration: 2, note: ["E3"]},
  # measure 21
  { duration: 8, note: ["A2",  "D3",  "F#3"]},
]

# --- LEFT HAND BASS: single note per half-measure (M1-16) ---
# Follows chord roots: D->A->B->F#->G->D->G->A
BASS_NOTES = [
  # measure 1-4
  { duration: 8, note: ["D3"] },  # chord 1 (D)
  { duration: 8, note: ["A2"] },  # chord 2 (A)
  { duration: 8, note: ["B2"] },  # chord 3 (Bm)
  { duration: 8, note: ["F#2"] }, # chord 4 (F#m)
  { duration: 8, note: ["G2"] },  # chord 5 (G)
  { duration: 8, note: ["D2"] },  # chord 6 (D)
  { duration: 8, note: ["G2"] },  # chord 7 (G)
  { duration: 8, note: ["A2"] },  # chord 8 (A)
  # measure 5-8
  { duration: 8, note: ["D3"] },  # chord 1 (D)
  { duration: 8, note: ["A2"] },  # chord 2 (A)
  { duration: 8, note: ["B2"] },  # chord 3 (Bm)
  { duration: 8, note: ["F#2"] }, # chord 4 (F#m)
  { duration: 8, note: ["G2"] },  # chord 5 (G)
  { duration: 8, note: ["D2"] },  # chord 6 (D)
  { duration: 8, note: ["G2"] },  # chord 7 (G)
  { duration: 8, note: ["A2"] },  # chord 8 (A)
  # measure 9-12
  { duration: 8, note: ["D2"] },  # chord 1 (D)
  { duration: 8, note: ["A1"] },  # chord 2 (A)
  { duration: 8, note: ["B1"] },  # chord 3 (Bm)
  { duration: 8, note: ["F#1"] }, # chord 4 (F#m)
  { duration: 8, note: ["G1"] },  # chord 5 (G)
  { duration: 8, note: ["D1"] },  # chord 6 (D)
  { duration: 8, note: ["G1"] },  # chord 7 (G)
  { duration: 8, note: ["A1"] },  # chord 8 (A)
  # measure 13-16
  { duration: 8, note: ["D2"] },  # chord 1 (D)
  { duration: 8, note: ["A1"] },  # chord 2 (A)
  { duration: 8, note: ["B1"] },  # chord 3 (Bm)
  { duration: 8, note: ["F#1"] }, # chord 4 (F#m)
  { duration: 8, note: ["G1"] },  # chord 5 (G)
  { duration: 8, note: ["D1"] },  # chord 6 (D)
  { duration: 8, note: ["G1"] },  # chord 7 (G)
  { duration: 8, note: ["A1"] },  # chord 8 (A)
  # measure 17-20
  { duration: 8, note: ["D2"] },  # chord 1 (D)
  { duration: 8, note: ["A1"] },  # chord 2 (A)
  { duration: 8, note: ["B1"] },  # chord 3 (Bm)
  { duration: 8, note: ["F#1"] }, # chord 4 (F#m)
  { duration: 8, note: ["G1"] },  # chord 5 (G)
  { duration: 8, note: ["D1"] },  # chord 6 (D)
  { duration: 8, note: ["G1"] },  # chord 7 (G)
  { duration: 8, note: ["A1"] },  # chord 8 (A)
  # measure 21
  { duration: 8, note: ["D2"] },  # chord 1 (D)
]

# --- LEFT HAND ARPEGGIO (M9-16) ---
# 4 eighth notes per half-measure: root-5th-3rd-5th pattern
LH_ARPEGGIO = [
  { duration: 128, note: [] },
  # measure 9-12
  { duration: 2, note: ["D2"] },
  { duration: 2, note: ["F#2"] },
  { duration: 4, note: ["A2"] },
  { duration: 2, note: ["A1"] },
  { duration: 2, note: ["E2"] },
  { duration: 4, note: ["A2"] },
  { duration: 2, note: ["B1"] },
  { duration: 2, note: ["F#2"] },
  { duration: 4, note: ["B2"] },
  { duration: 2, note: ["F#1"] },
  { duration: 2, note: ["C#2"] },
  { duration: 4, note: ["F#2"] },
  { duration: 2, note: ["G1"] },
  { duration: 2, note: ["D2"] },
  { duration: 4, note: ["G2"] },
  { duration: 2, note: ["D1"] },
  { duration: 2, note: ["A1"] },
  { duration: 4, note: ["D2"] },
  { duration: 2, note: ["G1"] },
  { duration: 2, note: ["D2"] },
  { duration: 4, note: ["G2"] },
  { duration: 2, note: ["A1"] },
  { duration: 2, note: ["E2"] },
  { duration: 4, note: ["A2"] },
  # measure 13-16
  { duration: 2, note: ["D2"] },
  { duration: 2, note: ["F#2"] },
  { duration: 4, note: ["A2"] },
  { duration: 2, note: ["A1"] },
  { duration: 2, note: ["E2"] },
  { duration: 4, note: ["A2"] },
  { duration: 2, note: ["B1"] },
  { duration: 2, note: ["F#2"] },
  { duration: 4, note: ["B2"] },
  { duration: 2, note: ["F#1"] },
  { duration: 2, note: ["C#2"] },
  { duration: 4, note: ["F#2"] },
  { duration: 2, note: ["G1"] },
  { duration: 2, note: ["D2"] },
  { duration: 4, note: ["G2"] },
  { duration: 2, note: ["D1"] },
  { duration: 2, note: ["A1"] },
  { duration: 4, note: ["D2"] },
  { duration: 2, note: ["G1"] },
  { duration: 2, note: ["D2"] },
  { duration: 4, note: ["G2"] },
  { duration: 2, note: ["A1"] },
  { duration: 2, note: ["E2"] },
  { duration: 4, note: ["A2"] },
  # measure 17-20
  { duration: 2, note: ["D2"] },
  { duration: 2, note: ["F#2"] },
  { duration: 4, note: ["A2"] },
  { duration: 2, note: ["A1"] },
  { duration: 2, note: ["E2"] },
  { duration: 4, note: ["A2"] },
  { duration: 2, note: ["B1"] },
  { duration: 2, note: ["F#2"] },
  { duration: 4, note: ["B2"] },
  { duration: 2, note: ["F#1"] },
  { duration: 2, note: ["C#2"] },
  { duration: 4, note: ["F#2"] },
  { duration: 2, note: ["G1"] },
  { duration: 2, note: ["D2"] },
  { duration: 4, note: ["G2"] },
  { duration: 2, note: ["D1"] },
  { duration: 2, note: ["A1"] },
  { duration: 4, note: ["D2"] },
  { duration: 2, note: ["G1"] },
  { duration: 2, note: ["D2"] },
  { duration: 4, note: ["G2"] },
  { duration: 2, note: ["A1"] },
  { duration: 2, note: ["E2"] },
  { duration: 4, note: ["A2"] },
]

# ---- Block helper ----
def make_block(start, length, note_specs, dim=3, chord_name = "custom")
  return nil if note_specs.empty?
  {
    start: start,
    length: length,
    notes: note_specs.map { |name| n(name, dim) },
    chord_name: chord_name,
    pattern_id: nil,
  }
end

def make_blocks(notes, dim=3)
  start = 0
  notes.map do |n|
    b = make_block(start, n[:duration]*2, n[:note], dim)
    start += n[:duration]*2
    b
  end.compact
end

# ---- Track template ----
def make_track(blocks)
  {
    type: "melodic",
    volume: 1.0,
    mute: false,
    solo: false,
    send: false,
    preset_name: "Bell1",
    blocks: blocks,
    arpeggiator: {
      enabled: true,
      mode: "up",
      division: 1,
      octaves: 1,
    },
    patch: "{\"nodes\":[{\"id\":\"vco\",\"type\":\"Oscillator\",\"params\":{\"type\":\"sine\"},\"freq_track\":true},{\"id\":\"vcf\",\"type\":\"BiquadFilter\",\"params\":{\"type\":\"bandpass\",\"frequency\":null,\"q\":1},\"freq_track\":false},{\"id\":\"vca\",\"type\":\"Gain\",\"params\":{\"gain\":1},\"freq_track\":false},{\"id\":\"env\",\"type\":\"ADSR\",\"params\":{\"attack\":0.05,\"decay\":0.2,\"sustain\":0.5,\"release\":0.5},\"freq_track\":false},{\"id\":\"oscillator\",\"type\":\"Oscillator\",\"params\":{\"type\":\"sine\",\"frequency\":2000},\"freq_track\":false},{\"id\":\"gain\",\"type\":\"Gain\",\"params\":{\"gain\":1000},\"freq_track\":false}],\"connections\":[{\"from\":\"vco\",\"to\":\"vcf\"},{\"from\":\"vcf\",\"to\":\"vca\"},{\"from\":\"vca\",\"to\":\"out\"},{\"from\":\"env\",\"to\":\"vca.gain\"},{\"from\":\"oscillator\",\"to\":\"gain\"},{\"from\":\"gain\",\"to\":\"vco.detune\"}]}"
  }
end

def make_project(dim)
  # ---- Build Track 1: Right Hand ----
  track1_blocks = make_blocks(RH, dim)

  # ---- Build Track 2: Bass Ostinato ----
  track2_blocks = make_blocks(BASS_NOTES, dim)

  # ---- Build Track 3: LH Arpeggio (M9-16 only) ----
  track3_blocks = make_blocks(LH_ARPEGGIO, dim)

  # ---- Assemble project ----
  project = {
    vertion: "1.0",
    timestamp: Time.now.iso8601,
    sequencer: {
      bpm: 84,
      swing: 0.0,
      root_freq: 261.63,
      total_steps: 1024,
      patterns: [],
      tracks: [
        make_track(track1_blocks),
        make_track(track2_blocks),
        make_track(track3_blocks),
      ],
    },
    chords: {},
    synthPresets: {},
  }

  project
end

# ---- Write JSON ----
File.write(File.join(__dir__, "canon_first16_3d.json"), JSON.pretty_generate(make_project(3)))
File.write(File.join(__dir__, "canon_first16_4d.json"), JSON.pretty_generate(make_project(4)))
File.write(File.join(__dir__, "canon_first16_5d.json"), JSON.pretty_generate(make_project(5)))
