require 'json'

class MIDIProcessor
  def initialize(sequencer, preview_synth, chord_synth)
    @sequencer     = sequencer
    @preview_synth = preview_synth
    @chord_synth   = chord_synth

    @current_tab        = "synth"
    @synth_dimension    = 3
    @synth_active_notes = {}
    @chord_dimension    = 3
    @chord_notes        = []
    @chord_pending      = {}
    @seq_editor_open    = false
    @seq_dimension      = 3
    @seq_notes          = []
    @seq_pending        = {}
  end

  def set_tab(tab)
    @current_tab = tab.to_s
  end

  def set_synth_dimension(d)
    @synth_dimension = d.to_i
  end

  def set_chord_dimension(d)
    @chord_dimension = d.to_i
  end

  def set_chord_notes(json)
    @chord_notes = JSON.parse(json.to_s, symbolize_names: true)
  end

  def get_chord_notes_json
    @chord_notes.to_json
  end

  def set_seq_editor_open(v)
    @seq_editor_open = (v == true || v.to_s == "true")
  end

  def set_seq_dimension(d)
    @seq_dimension = d.to_i
  end

  def set_seq_notes(json)
    @seq_notes = JSON.parse(json.to_s, symbolize_names: true)
  end

  def get_seq_notes_json
    @seq_notes.to_json
  end

  def process(status, data1, data2)
    status = status.to_i
    data1  = data1.to_i
    data2  = data2.to_i
    case status & 0xF0
    when 0x90
      data2 > 0 ? handle_note_on(data1, data2) : handle_note_off(data1)
    when 0x80
      handle_note_off(data1)
    when 0xB0
      handle_cc(data1, data2)
    else
      noop
    end
  end

  private

  def handle_note_on(note, _velocity)
    case @current_tab
    when "synth"
      coords = midi_note_to_lattice(note, @synth_dimension)
      freq   = calc_freq(coords)
      @preview_synth.note_on(freq)
      @synth_active_notes[note] = freq
      noop
    when "chord"
      chord_note_on(note, @chord_notes, @chord_pending, @chord_dimension, @chord_synth)
      noop
    when "seq"
      chord_note_on(note, @seq_notes, @seq_pending, @seq_dimension, @chord_synth) if @seq_editor_open
      noop
    else
      noop
    end
  end

  def handle_note_off(note)
    case @current_tab
    when "synth"
      freq = @synth_active_notes.delete(note)
      @preview_synth.note_off(freq) if freq
      noop
    when "chord"
      changed = chord_note_off(note, @chord_notes, @chord_pending, @chord_dimension, @chord_synth)
      changed ? { type: "re_render_chord" }.to_json : noop
    when "seq"
      if @seq_editor_open
        changed = chord_note_off(note, @seq_notes, @seq_pending, @seq_dimension, @chord_synth)
        return changed ? { type: "re_render_seq" }.to_json : noop
      end
      noop
    else
      noop
    end
  end

  def handle_cc(cc, value)
    case cc
    when 7
      vol = value / 127.0
      @sequencer.master_volume = vol
      { type: "update_master_volume", value: vol }.to_json
    when 20
      dim = value.to_i
      return noop unless [3, 4, 5].include?(dim)
      if @current_tab == "chord"
        transcribe_dimension(@chord_notes, @chord_dimension, dim)
        @chord_dimension = dim
        { type: "re_render_chord", dimension: dim }.to_json
      elsif @current_tab == "seq" && @seq_editor_open
        transcribe_dimension(@seq_notes, @seq_dimension, dim)
        @seq_dimension = dim
        { type: "re_render_seq", dimension: dim }.to_json
      elsif @current_tab == "synth"
        @synth_dimension = dim
        { type: "set_synth_dimension", dimension: dim }.to_json
      else
        noop
      end
    when 23
      delta   = value - 64
      pending = @current_tab == "chord" ? @chord_pending : @seq_pending
      last_key = pending.keys.last
      pending[last_key][:delta] = delta if last_key
      noop
    else
      noop
    end
  end

  def chord_note_on(note, notes, pending, dim, _synth)
    coords   = midi_note_to_lattice(note, dim)
    x        = coords[:b]
    y        = y_from_coords(coords, dim)
    existing = find_note(notes, x, y, dim)
    base_a   = existing ? existing[:a] : 0
    pending[note] = { x: x, y: y, delta: 0, base_a: base_a }
  end

  def chord_note_off(note, notes, pending, dim, synth)
    state = pending.delete(note)
    return false unless state
    if state[:delta] != 0
      change_octave(notes, state[:x], state[:y], state[:delta], dim)
    else
      toggle_note(notes, state[:x], state[:y], dim)
    end
    committed = find_note(notes, state[:x], state[:y], dim)
    if committed
      freq = calc_freq({ a: committed[:a], b: committed[:b], c: committed[:c], d: committed[:d], e: committed[:e] })
      synth.schedule_note(freq, @sequencer.ctx_current_time, 0.3)
    end
    true
  end

  def toggle_note(notes, x, y, dim)
    idx = notes.index { |n| matches_coord?(n, x, y, dim) }
    if idx
      notes.delete_at(idx)
    else
      n = { a: 0, b: x, c: 0, d: 0, e: 0 }
      n[:c] = y if dim == 3
      n[:d] = y if dim == 4
      n[:e] = y if dim == 5
      notes << n
    end
  end

  def change_octave(notes, x, y, delta, dim)
    note = notes.find { |n| matches_coord?(n, x, y, dim) }
    if note
      note[:a] += delta
    else
      n = { a: delta, b: x, c: 0, d: 0, e: 0 }
      n[:c] = y if dim == 3
      n[:d] = y if dim == 4
      n[:e] = y if dim == 5
      notes << n
    end
  end

  def transcribe_dimension(notes, _old_dim, new_dim)
    notes.each do |n|
      y_val = 0
      if n[:c] && n[:c] != 0
        y_val = n[:c]
      elsif n[:d] && n[:d] != 0
        y_val = n[:d]
      elsif n[:e] && n[:e] != 0
        y_val = n[:e]
      end
      n[:c] = 0; n[:d] = 0; n[:e] = 0
      n[:c] = y_val if new_dim == 3
      n[:d] = y_val if new_dim == 4
      n[:e] = y_val if new_dim == 5
    end
  end

  def midi_note_to_lattice(note_number, dim)
    idx   = note_number - 36
    b     = idx % 9 - 4
    y_rel = idx / 9 - 4
    {
      a: 0, b: b,
      c: dim == 3 ? y_rel : 0,
      d: dim == 4 ? y_rel : 0,
      e: dim == 5 ? y_rel : 0
    }
  end

  def y_from_coords(coords, dim)
    case dim
    when 3 then coords[:c]
    when 4 then coords[:d]
    else        coords[:e]
    end
  end

  def matches_coord?(n, x, y, dim)
    return false unless n[:b] == x
    case dim
    when 3 then n[:c] == y
    when 4 then n[:d] == y
    else        n[:e] == y
    end
  end

  def find_note(notes, x, y, dim)
    notes.find { |n| matches_coord?(n, x, y, dim) }
  end

  def calc_freq(coords)
    @sequencer.calculate_freq_from_coords(
      coords[:a], coords[:b], coords[:c], coords[:d], coords[:e]
    ).to_f
  end

  def noop
    '{"type":"noop"}'
  end
end
