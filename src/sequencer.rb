require "js"
require "json"
require_relative "synthesizer/drum_machine"
require_relative "effects_chain"

# Structure to hold lattice coordinates
# a: 1st dim (2.0) - Octave
# b: 2nd dim (3.0/2.0) - X axis
# c: 3rd dim (5.0/4.0) - Y axis candidate
# d: 4th dim (7.0/4.0) - Y axis candidate
# e: 5th dim (11.0/4.0) - Y axis candidate
NoteCoord = Struct.new(:a, :b, :c, :d, :e) do
  def to_json_object
    { a: a, b: b, c: c, d: d, e: e }
  end
end

class Arpeggiator
  attr_accessor :enabled, :mode, :division, :octaves

  def initialize
    @enabled = false
    @mode = :up
    @division = 1 # 1 step = 1/32 note
    @octaves = 1
  end

  def to_json_object
    { enabled: @enabled, mode: @mode, division: @division, octaves: @octaves }
  end
end

Block = Struct.new(:start_step, :length, :notes, :chord_name, :pattern_id) do
  def to_json_object
    {
      start: start_step,
      length: length,
      notes: notes.map(&:to_json_object),
      chord_name: chord_name,
      pattern_id: pattern_id
    }
  end
end

RhythmPattern = Struct.new(:id, :name, :steps, :events) do
  # events: Hash { instrument_name => { step_index => velocity(0.0..1.0) } }
  def to_json_object
    {
      id: id,
      name: name,
      steps: steps,
      events: events
    }
  end
end

class Track
  attr_accessor :blocks, :synth, :mute, :preset_name, :solo, :type
  attr_reader :volume, :arpeggiator, :send_gain

  def initialize(ctx, synth, type = :melodic)
    @synth = synth
    @type = type # :melodic or :rhythmic
    @blocks = []
    @mute = false
    @solo = false
    @preset_name = ""
    @volume = 1.0
    @arpeggiator = Arpeggiator.new

    # Send Gain for Effects
    @send_gain = GainNode.new(ctx, gain: 0.0) # Default Send Off
  end

  def volume=(val)
    @volume = val.to_f
    @synth.volume = @volume
  end

  def send_enabled=(enabled)
    @send_gain.gain.value = enabled ? 1.0 : 0.0
  end

  def send_enabled
    @send_gain.gain.value > 0.5
  end

  def add_block(start_step, length, pattern_id = nil)
    block = Block.new(start_step, length, [], "", pattern_id)
    @blocks << block
    block
  end

  def remove_block_at(start_step)
    @blocks.reject! { |b| b.start_step == start_step }
  end

  def find_block_at(step)
    @blocks.find { |b| b.start_step <= step && (b.start_step + b.length) > step }
  end
end

class Sequencer
  attr_accessor :bpm
  attr_accessor :root_freq
  attr_accessor :swing_amount # 0.0 to 1.0 (0 = straight, >0 = swing)

  attr_reader :is_playing, :current_step, :tracks, :current_track_index, :total_steps, :start_step
  attr_reader :patterns, :name
  attr_reader :effects_chain

  def initialize(ctx, name: "$sequencer")
    @ctx = ctx
    @name = name # The Ruby global variable name or identifier
    @bpm = 120
    @root_freq = 261.63 # C4
    @swing_amount = 0.0

    @total_steps = 128 # Default 4 bars (32 steps * 4)

    # --- Master Bus ---
    @master_gain = GainNode.new(@ctx, gain: 1.0)

    # --- Effects Bus (Send/Return) ---
    @effects_chain = EffectsChain.new(@ctx)
    @send_bus = GainNode.new(@ctx, gain: 1.0)

    # Routing: Send Bus -> Effects Chain -> Master (Return)
    @send_bus.connect(@effects_chain.input_node)
    @effects_chain.connect(@master_gain)

    # --- Compressor & Output ---
    @compressor = DynamicsCompressorNode.new(@ctx)
    @compressor.threshold.value = -24.0
    @compressor.knee.value = 30.0
    @compressor.ratio.value = 12.0
    @compressor.attack.value = 0.003
    @compressor.release.value = 0.25

    @master_gain.connect(@compressor)
    @compressor.connect(@ctx[:destination])

    @tracks = []
    @patterns = []

    # Initialize one melody track (optional for pattern sequencer)
    # We only add it for the main sequencer for now
    if @name == "$sequencer"
      add_track
      create_pattern("Pattern 1")
    end

    @is_playing = false
    @current_step = 0
    @start_step = 0
    @next_note_time = 0.0
    @schedule_ahead_time = 0.1
    @lookahead_ms = 25.0
  end

  def total_bars
    @total_steps / 32
  end

  def set_total_bars(bars)
    @total_steps = bars.to_i * 32
    @start_step = @total_steps - 1 if @start_step >= @total_steps
    @start_step = 0 if @start_step < 0
  end

  def set_start_step(step)
    s = step.to_i
    max = @total_steps - 1
    s = 0 if s < 0
    s = max if s > max
    @start_step = s
  end

  def set_bpm(bpm)
    @bpm = bpm.to_i
  end

  def set_root_freq(freq)
    @root_freq = freq.to_f
  end

  def set_swing_amount(amount)
    @swing_amount = amount.to_f
  end

  def get_track_type(index)
    @tracks[index]&.type.to_s
  end

  def set_track_mute(index, mute)
    t = @tracks[index]
    t.mute = (mute == true || mute == "true") if t
  end

  def set_track_solo(index, solo)
    t = @tracks[index]
    t.solo = (solo == true || solo == "true") if t
  end

  def set_track_volume(index, vol)
    t = @tracks[index]
    t.volume = vol.to_f if t
  end

  def master_volume
    @master_gain.gain.value
  end

  def master_volume=(val)
    @master_gain.gain.value = val.to_f.clamp(0.0, 1.0)
  end

  def ctx_current_time
    @ctx[:currentTime].to_f
  end

  def get_track_volume(index)
    @tracks[index]&.volume || 1.0
  end

  def set_track_send(index, enabled)
    t = @tracks[index]
    t.send_enabled = (enabled == true || enabled == "true") if t
  end

  def get_track_send(index)
    @tracks[index]&.send_enabled || false
  end

  def get_track_preset_name(index)
    @tracks[index]&.preset_name || ""
  end

  def set_track_preset_name(index, name)
    t = @tracks[index]
    t.preset_name = name.to_s if t
  end

  def import_track_patch(index, json)
    t = @tracks[index]
    t.synth.import_patch(json) if t
  end

  def get_track_mute(index)
    @tracks[index]&.mute ? true : false
  end

  def get_track_solo(index)
    @tracks[index]&.solo ? true : false
  end

  def set_block_chord_name(track_index, start_step, name)
    t = @tracks[track_index]
    return unless t
    b = t.blocks.find { |blk| blk.start_step == start_step }
    b.chord_name = name.to_s if b
  end

  def set_block_pattern_id(track_index, start_step, pattern_id)
    t = @tracks[track_index]
    return unless t
    b = t.blocks.find { |blk| blk.start_step == start_step }
    b.pattern_id = pattern_id.to_s if b
  end

  def get_block_pattern_id(track_index, start_step)
    t = @tracks[track_index]
    return nil unless t
    b = t.blocks.find { |blk| blk.start_step == start_step }
    b&.pattern_id
  end

  def get_tracks_count
    @tracks.length
  end

  def set_block_notes_from_buffer(track_index, start_step, buffer)
    # buffer expected to be a JS::Object (Float32Array)
    update_block_notes_buffer(track_index, start_step, buffer)
  end

  # Ruby-friendly variant accepting an array of note hashes ({a,b,c,d,e} keys
  # may be either strings or symbols, missing keys default to 0).
  def set_block_notes(track_index, start_step, notes)
    track = @tracks[track_index.to_i]
    return unless track
    return if track.type == :rhythmic

    block = track.blocks.find { |b| b.start_step == start_step.to_i }
    return unless block

    block.notes.clear
    notes.each do |n|
      block.notes << NoteCoord.new(
        (n["a"] || n[:a] || 0).to_f,
        (n["b"] || n[:b] || 0).to_f,
        (n["c"] || n[:c] || 0).to_f,
        (n["d"] || n[:d] || 0).to_f,
        (n["e"] || n[:e] || 0).to_f
      )
    end
  end

  def add_track
    synth = Synthesizer.new(@ctx)
    # Routing:
    # 1. Synth -> Master (Dry)
    synth.connect(@master_gain)

    track = Track.new(@ctx, synth, :melodic)
    # 2. Synth -> SendGain -> SendBus (Wet Send)
    synth.connect(track.send_gain)
    track.send_gain.connect(@send_bus)

    @tracks << track
    select_track(@tracks.length - 1)
    track
  end

  def add_rhythm_track
    drum_machine = DrumMachine.new(@ctx)
    drum_machine.connect(@master_gain)

    track = Track.new(@ctx, drum_machine, :rhythmic)

    # Send routing for DrumMachine too
    drum_machine.connect(track.send_gain)
    track.send_gain.connect(@send_bus)

    track.preset_name = "Drum Kit"
    @tracks << track
    select_track(@tracks.length - 1)
    track
  end

  def remove_track(index)
    return if @tracks.length <= 1 # Keep at least one track
    return if index < 0 || index >= @tracks.length

    track = @tracks.delete_at(index)
    track.synth.close
    track.send_gain.disconnect # Disconnect from SendBus

    if @current_track_index >= @tracks.length
      @current_track_index = @tracks.length - 1
    end
    # Reselect to update analyser connection
    select_track(@current_track_index)
  end

  def select_track(index)
    if index >= 0 && index < @tracks.length
      @current_track_index = index
    end
  end

  def current_track
    @tracks[@current_track_index]
  end

  # --- Pattern Management ---

  def create_pattern(name = "New Pattern", steps = 16, id = nil)
    id ||= "p#{@patterns.length + 1}_#{(Time.now.to_f * 1000).to_i}"
    # Initialize with velocity hash for each instrument
    events = {
      "Kick" => {}, "Snare" => {}, "HiHat" => {}, "OpenHat" => {}
    }
    pattern = RhythmPattern.new(id, name, steps, events)
    @patterns << pattern
    pattern
  end

  def delete_pattern(id)
    @patterns.reject! { |p| p.id == id }
    # Reset references in rhythm blocks that used the deleted pattern
    @tracks.each do |t|
      next unless t.type == :rhythmic
      t.blocks.each do |b|
        if b.pattern_id == id
          # Reset to first available or nil
          b.pattern_id = @patterns.first&.id
        end
      end
    end
  end

  def rename_pattern(id, new_name)
    p = get_pattern(id)
    p.name = new_name if p
  end

  def get_pattern(id)
    @patterns.find { |p| p.id == id }
  end

  # Internal helper for sharing between instances
  def get_pattern_by_id_internal(id)
    get_pattern(id)
  end

  # For shared patterns, we will just use the global $sequencer's patterns if this is a preview sequencer
  def set_patterns_reference(patterns)
    @patterns = patterns
  end

  def get_pattern_name(id)
    p = get_pattern(id)
    p ? p.name : id
  end

  def get_patterns_json
    JSON.generate(@patterns.map { |p| { id: p.id, name: p.name, steps: p.steps } })
  end

  def export_patterns_json
    items = @patterns.map do |p|
      {
        id: p.id,
        name: p.name,
        steps: p.steps,
        events: normalize_events(p.events)
      }
    end
    JSON.generate(items)
  end

  def import_patterns_json(json)
    parsed = JSON.parse(json.to_s, symbolize_names: true) rescue nil
    return unless parsed.is_a?(Array)

    @patterns.clear

    parsed.each do |p_data|
      id = p_data[:id].to_s
      name = p_data[:name].to_s
      steps = p_data[:steps].to_i
      events = normalize_events(p_data[:events] || {})

      pattern = RhythmPattern.new(id, name, steps, events)
      @patterns << pattern
    end

    # Ensure at least one pattern exists
    if @patterns.empty?
      create_pattern("Pattern 1")
    end
  end

  # --- Block Management ---

  def add_or_update_block(track_index, start_step, length, pattern_id = nil)
    track = @tracks[track_index]
    return unless track

    existing = track.blocks.find { |b| b.start_step == start_step }
    if existing
      existing.length = length
      existing.pattern_id = pattern_id if pattern_id
    else
      # If rhythm track and no pattern_id provided, use the first available pattern
      if track.type == :rhythmic && pattern_id.nil?
        pattern_id = @patterns.first&.id
      end
      track.add_block(start_step, length, pattern_id)
    end
  end

  def remove_block(track_index, start_step)
    track = @tracks[track_index]
    return unless track
    track.remove_block_at(start_step)
  end

  # Used by Lattice Editor to edit specific block
  def get_block_notes_json(track_index, start_step)
    track = @tracks[track_index]
    return "[]" unless track

    block = track.blocks.find { |b| b.start_step == start_step }
    return "[]" unless block

    JSON.generate(block.notes.map(&:to_json_object))
  end

  def update_block_notes(track_index, start_step, notes_json_str)
    track = @tracks[track_index]
    return unless track
    return if track.type == :rhythmic # Rhythm blocks don't store notes this way

    block = track.blocks.find { |b| b.start_step == start_step }
    return unless block

    block.notes.clear
    notes = JSON.parse(notes_json_str.to_s, symbolize_names: true) rescue []
    return unless notes.is_a?(Array)

    notes.each do |n|
       new_note = NoteCoord.new(n[:a].to_f, n[:b].to_f, n[:c].to_f, n[:d].to_f, n[:e].to_f)
       block.notes << new_note
    end
  end

  def update_block_notes_buffer(track_index, start_step, flat_array)
    t_idx = track_index.to_i
    s_step = start_step.to_i
    track = @tracks[t_idx]
    return unless track
    return if track.type == :rhythmic

    block = track.blocks.find { |b| b.start_step == s_step }
    return unless block

    block.notes.clear
    len = flat_array[:length].to_i
    count = len / 5
    count.times do |i|
       base = i * 5
       new_note = NoteCoord.new(
         flat_array[base].to_f, flat_array[base+1].to_f,
         flat_array[base+2].to_f, flat_array[base+3].to_f, flat_array[base+4].to_f
       )
       block.notes << new_note
    end
  end

  # Pattern Editor Integration
  def toggle_pattern_step(pattern_id, instrument, step, velocity = 0.8)
    pattern = get_pattern(pattern_id)
    return unless pattern

    steps_map = pattern.events[instrument] || {}
    if steps_map.has_key?(step)
      steps_map.delete(step)
    else
      steps_map[step] = velocity
    end
    pattern.events[instrument] = steps_map
  end

  def get_pattern_events_json(pattern_id)
    pattern = get_pattern(pattern_id)
    return "{}" unless pattern

    JSON.generate(normalize_events(pattern.events))
  end

  def get_track_blocks_json(track_index)
    track = @tracks[track_index]
    return "[]" unless track

    JSON.generate(track_blocks_data(track))
  end

  # Everything renderSequencer (sequencer_ui.js) needs for one full redraw,
  # bundled into a single bridge call instead of 2-3 calls per track.
  def get_render_state_json
    JSON.generate({
      total_steps: @total_steps,
      start_step: @start_step,
      tracks: @tracks.map { |t| { type: t.type, blocks: track_blocks_data(t) } }
    })
  end

  def track_blocks_data(track)
    track.blocks.map do |b|
      res = {
        start: b.start_step,
        length: b.length,
        notes_count: b.notes.length,
        type: track.type
      }
      res[:pattern_id] = b.pattern_id if track.type == :rhythmic
      res
    end
  end

  # --- Playback ---

  def start
    return if @is_playing
    @is_playing = true
    @current_step = @start_step
    @next_note_time = @ctx[:currentTime].to_f + 0.1

    # Use unique interval name based on instance name.
    # Go through App.eval (not raw vm.eval) so a scheduler exception is
    # logged once per tick instead of thrown uncaught every 25ms.
    interval_name = "seqInterval_#{@name.gsub('$', '')}"
    code = <<~JAVASCRIPT
      window.App["#{interval_name}"] = setInterval(() => {
        if (window.App && window.App.vm) {
          window.App.eval("#{@name}.scheduler", "Scheduler");
        }
      }, #{@lookahead_ms});
    JAVASCRIPT
    JS.eval(code)
  end

  def stop
    @is_playing = false
    interval_name = "seqInterval_#{@name.gsub('$', '')}"
    JS.eval("clearInterval(window.App['#{interval_name}']); delete window.App['#{interval_name}'];")
  end

  def scheduler
    updates = []
    while @next_note_time < @ctx[:currentTime].to_f + @schedule_ahead_time
      schedule_step(@current_step, @next_note_time)
      updates << { step: @current_step, time: @next_note_time, sequencer: @name }
      advance_step
    end

    if updates.any?
      JS.global[:App].call(:queuePlayheadUpdates, JSON.generate(updates))
    end
  end

  def schedule_step(step_index, time)
    seconds_per_beat = 60.0 / @bpm
    step_duration_sec = seconds_per_beat / 8.0 # 1/32 note resolution base

    # Apply Swing
    swing_offset = 0.0
    if (step_index % 4) == 2
      swing_offset = (step_duration_sec * 2) * (@swing_amount * 0.33)
    end

    play_time = time + swing_offset

    any_solo = @tracks.any?(&:solo)

    @tracks.each do |track|
      next if track.mute
      next if any_solo && !track.solo

      if track.type == :melodic
        blocks = track.blocks.select { |b| b.start_step == step_index }
        blocks.each do |block|
          next if block.notes.empty?

          if track.arpeggiator.enabled
            block.notes.each_with_index do |note, idx|
              delay_steps = idx * track.arpeggiator.division
              next if delay_steps >= block.length

              note_start_time = play_time + (delay_steps * step_duration_sec)
              note_duration = (block.length - delay_steps) * step_duration_sec
              freq = calculate_freq(note)
              track.synth.schedule_note(freq, note_start_time, note_duration)
            end
          else
            duration = block.length * step_duration_sec
            block.notes.each do |note|
              freq = calculate_freq(note)
              track.synth.schedule_note(freq, play_time, duration)
            end
          end
        end
      elsif track.type == :rhythmic
        block = track.find_block_at(step_index)
        next unless block && block.pattern_id

        pattern = get_pattern(block.pattern_id)
        next unless pattern

        local_step_abs = step_index - block.start_step
        # Sequencer runs at 1/32 note resolution, but drum patterns use 1/16 note steps,
        # so each pattern step spans 2 sequencer steps.
        pattern_seq_length = pattern.steps * 2
        local_pos = local_step_abs % pattern_seq_length

        if (local_pos % 2) == 0
          pattern_step_index = local_pos / 2

          pattern.events.each do |instrument, steps_map|
            if steps_map.has_key?(pattern_step_index)
              velocity = steps_map[pattern_step_index]
              track.synth.trigger(instrument, play_time, velocity)
            end
          end
        end
      end
    end
  end

  def set_arpeggiator_enabled(track_index, enabled)
    track = @tracks[track_index]
    if track && track.type == :melodic
      track.arpeggiator.enabled = (enabled == true || enabled == "true")
    end
  end

  def get_arpeggiator_status(track_index)
    track = @tracks[track_index]
    (track && track.type == :melodic && track.arpeggiator.enabled) ? true : false
  end

  # Normalize pattern events data, handling legacy Array format and JSON-parsed keys.
  # Ensures instrument keys are strings, step keys are integers, and velocities are floats.
  def normalize_events(raw_events)
    clean = {}
    raw_events.each do |inst, data|
      step_map = {}
      if data.is_a?(Hash)
        data.each { |k, v| step_map[k.to_s.to_i] = v.to_f }
      elsif data.is_a?(Array)
        data.each { |s| step_map[s.to_i] = 0.8 }
      end
      clean[inst.to_s] = step_map
    end
    clean
  end

  def calculate_freq(note)
    # F = R * (2^a) * ((3/2)^b) * ((5/4)^c) * ((7/4)^d) * ((11/4)^e)
    f = @root_freq * (2.0 ** note.a)
    f *= (1.5 ** note.b)
    f *= (1.25 ** note.c)
    f *= (1.75 ** note.d)
    f *= (2.75 ** note.e)
    f
  end

  def calculate_freq_from_coords(a, b, c, d, e)
    n = NoteCoord.new(a.to_f, b.to_f, c.to_f, d.to_f, e.to_f)
    calculate_freq(n)
  end

  def advance_step
    seconds_per_beat = 60.0 / @bpm
    # 1 step = 1/32 bar = 1/8 beat
    @next_note_time += (seconds_per_beat / 8.0)

    @current_step += 1
    # Loop at total_steps
    if @current_step >= @total_steps
      @current_step = 0
    end
  end

  # --- Project Serialization ---

  def serialize_project
    {
      bpm: @bpm,
      swing: @swing_amount,
      root_freq: @root_freq,
      total_steps: @total_steps,
      patterns: @patterns.map(&:to_json_object),
      tracks: @tracks.map { |t|
        data = {
          type: t.type,
          volume: t.volume,
          mute: t.mute,
          solo: t.solo,
          send: t.send_enabled,
          preset_name: t.preset_name,
          blocks: t.blocks.map(&:to_json_object),
          arpeggiator: t.arpeggiator.to_json_object
        }
        if t.type == :melodic
          data[:patch] = t.synth.export_patch
        end
        data
      }
    }.to_json
  end

  def deserialize_project(json)
    data = JSON.parse(json, symbolize_names: true) rescue nil
    return unless data

    stop if @is_playing

    # 1. Restore Global Settings
    @bpm = data[:bpm].to_i
    @swing_amount = data[:swing].to_f
    @root_freq = data[:root_freq].to_f
    @total_steps = data[:total_steps].to_i

    # 2. Restore Patterns
    @patterns.clear
    (data[:patterns] || []).each do |p_data|
      events = normalize_events(p_data[:events] || {})
      pattern = RhythmPattern.new(
        p_data[:id],
        p_data[:name],
        p_data[:steps].to_i,
        events
      )
      @patterns << pattern
    end

    # 3. Restore Tracks
    # Clear existing tracks
    while @tracks.length > 0
      track = @tracks.shift
      track.synth.close
      track.send_gain.disconnect
    end
    @current_track_index = 0

    (data[:tracks] || []).each do |t_data|
      type = t_data[:type].to_sym
      track = nil

      if type == :rhythmic
        track = add_rhythm_track
      else
        track = add_track
        # Restore Synth Patch
        if t_data[:patch]
          track.synth.import_patch(t_data[:patch])
        end
      end

      # Restore Track Settings
      track.volume = t_data[:volume].to_f
      track.mute = t_data[:mute]
      track.solo = t_data[:solo]
      track.send_enabled = t_data[:send]
      track.preset_name = t_data[:preset_name]

      # Restore Arpeggiator
      if t_data[:arpeggiator]
        arp = t_data[:arpeggiator]
        track.arpeggiator.enabled = arp[:enabled]
        track.arpeggiator.mode = arp[:mode].to_sym
        track.arpeggiator.division = arp[:division].to_i
        track.arpeggiator.octaves = arp[:octaves].to_i
      end

      # Restore Blocks
      (t_data[:blocks] || []).each do |b_data|
        block = track.add_block(b_data[:start].to_i, b_data[:length].to_i, b_data[:pattern_id])
        block.chord_name = b_data[:chord_name]

        # Restore Notes
        (b_data[:notes] || []).each do |n|
          block.notes << NoteCoord.new(
            n[:a].to_f, n[:b].to_f, n[:c].to_f, n[:d].to_f, n[:e].to_f
          )
        end
      end
    end
  end
end
