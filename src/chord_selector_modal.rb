require 'js'
require 'json'
require 'web_component'

class ChordSelectorModal
  include WebComponent

  DIMENSION_COLORS = {
    1 => "#ffffff", 2 => "#ff7f50", 3 => "#20b2aa",
    4 => "#9370db", 5 => "#ffc247", 6 => "#ffd700", 7 => "#cd5c5c"
  }

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]

    @editor_notes = []
    @editor_selected_cell = { x: 0, y: 0 }
    @track_idx = -1
    @start_step = -1
    @drag_state = nil

    style_host_hidden
    build_dom

    # Expose globally so other Ruby components (e.g. <sequencer-block>) can call open.
    $chord_selector_modal = self
  end

  def disconnected_callback
    $chord_selector_modal = nil if $chord_selector_modal.equal?(self)
  end

  def open(track_idx, start_step)
    @track_idx = track_idx.to_i
    @start_step = start_step.to_i
    @editor_notes = []
    @editor_selected_cell = { x: 0, y: 0 }

    notes_json = $sequencer.get_block_notes_json(@track_idx, @start_step).to_s
    parsed = JSON.parse(notes_json) rescue nil
    @editor_notes = JSON.parse(parsed.to_json) if parsed && !parsed.empty?

    inferred = 3
    inferred = 5 if @editor_notes.any? { |n| (n["e"] || 0) != 0 }
    inferred = 4 if inferred == 3 && @editor_notes.any? { |n| (n["d"] || 0) != 0 }
    @y_axis[:value] = inferred.to_s

    sync_to_ruby
    render_lattice
    render_chord_list

    $midiProcessor&.set_seq_editor_open(true)
    show
  end

  def close
    $midiProcessor&.set_seq_editor_open(false)
    hide
  end

  def re_render_seq
    json = $midiProcessor.get_seq_notes_json
    @editor_notes = JSON.parse(json.to_s)
    render_lattice
  rescue => e
    puts "[ChordSelectorModal] re_render_seq error: #{e.message}"
  end

  def set_seq_dimension(dim)
    @y_axis[:value] = dim.to_s
  end

  # exposed for the JS-side mousemove/mouseup callbacks
  def on_drag_move(client_y)
    return unless @drag_state
    delta = ((@drag_state[:start_y] - client_y) / 30.0).round
    @drag_state[:delta] = delta
    display_a = @drag_state[:has_note] ? @drag_state[:base_a] + delta : delta
    cell = @drag_state[:cell]
    if display_a > 0
      cell[:textContent] = "↑#{display_a}"
    elsif display_a < 0
      cell[:textContent] = "↓#{display_a.abs}"
    else
      cell[:textContent] = ""
    end
  end

  def on_drag_end
    return unless @drag_state
    x = @drag_state[:x]; y = @drag_state[:y]; delta = @drag_state[:delta]
    @drag_state = nil
    if delta != 0
      shift_octave(x, y, delta)
    else
      toggle_note(x, y)
    end
  end

  private

  def build_dom
    panel = create_div(
      width: "500px", maxWidth: "90%", height: "80%",
      display: "flex", flexDirection: "column"
    )
    panel[:className] = "panel"

    # Header
    header = create_div(
      display: "flex", justifyContent: "space-between", alignItems: "center",
      marginBottom: "15px", borderBottom: "1px solid #555", paddingBottom: "10px"
    )
    h2 = @doc.call(:createElement, "h2")
    h2[:textContent] = "Edit / Select Chord"
    style(h2, margin: "0", border: "none", padding: "0")
    header.call(:appendChild, h2)

    close_btn = @doc.call(:createElement, "button")
    close_btn[:textContent] = "Close"
    style(close_btn, padding: "5px 10px", background: "#dc3545")
    close_btn.call(:addEventListener, "click", proc { close })
    header.call(:appendChild, close_btn)
    panel.call(:appendChild, header)

    # Editor section
    editor = create_div(
      borderBottom: "1px solid #555", paddingBottom: "10px", marginBottom: "10px"
    )
    controls = create_div(
      display: "flex", alignItems: "center", gap: "10px", marginBottom: "8px"
    )
    label = @doc.call(:createElement, "label")
    label[:textContent] = "Y-Axis:"
    style(label, fontSize: "0.85rem", color: "#ccc")
    controls.call(:appendChild, label)

    @y_axis = @doc.call(:createElement, "select")
    @y_axis[:style][:padding] = "2px 4px"
    [[3, "dim3 (5-limit)"], [4, "dim4 (7-limit)"], [5, "dim5 (11-limit)"]].each do |val, txt|
      opt = @doc.call(:createElement, "option")
      opt[:value] = val.to_s
      opt[:textContent] = txt
      @y_axis.call(:appendChild, opt)
    end
    @y_axis.call(:addEventListener, "change", proc { on_y_axis_change })
    controls.call(:appendChild, @y_axis)

    clear_btn = @doc.call(:createElement, "button")
    clear_btn[:textContent] = "Clear"
    style(clear_btn, padding: "4px 10px", fontSize: "0.8rem", background: "#666")
    clear_btn.call(:addEventListener, "click", proc { on_clear })
    controls.call(:appendChild, clear_btn)

    spacer = create_div(flexGrow: "1")
    controls.call(:appendChild, spacer)

    apply_btn = @doc.call(:createElement, "button")
    apply_btn[:textContent] = "Apply"
    style(apply_btn, padding: "6px 16px", background: "#28a745", fontWeight: "bold")
    apply_btn.call(:addEventListener, "click", proc { on_apply })
    controls.call(:appendChild, apply_btn)

    editor.call(:appendChild, controls)

    @lattice = create_div(
      display: "grid", gridTemplateColumns: "repeat(9, 1fr)", gap: "2px",
      maxWidth: "350px", margin: "0 auto"
    )
    editor.call(:appendChild, @lattice)
    panel.call(:appendChild, editor)

    # Saved chord list
    @list_el = create_div(
      flexGrow: "1", overflowY: "auto", display: "grid",
      gridTemplateColumns: "repeat(auto-fill, minmax(100px, 1fr))", gap: "10px"
    )
    panel.call(:appendChild, @list_el)

    @element.call(:appendChild, panel)
  end

  def style_host_hidden
    s = @element[:style]
    s[:display] = "none"
    s[:position] = "fixed"
    s[:top] = "0"
    s[:left] = "0"
    s[:width] = "100%"
    s[:height] = "100%"
    s[:background] = "rgba(0,0,0,0.8)"
    s[:zIndex] = "3000"
    s[:alignItems] = "center"
    s[:justifyContent] = "center"
  end

  def show
    @element[:style][:display] = "flex"
  end

  def hide
    @element[:style][:display] = "none"
  end

  def on_clear
    @editor_notes = []
    @editor_selected_cell = { x: 0, y: 0 }
    sync_to_ruby
    render_lattice
  end

  def on_apply
    return if @editor_notes.empty?
    $sequencer.set_block_notes(@track_idx, @start_step, @editor_notes)
    $sequencer.set_block_chord_name(@track_idx, @start_step, "custom")
    # Defer the event dispatch so its listener (which calls back into Ruby)
    # runs after the current Ruby stack unwinds — synchronous dispatchEvent
    # here would trigger a forbidden nested VM operation.
    JS.eval("setTimeout(() => window.dispatchEvent(new Event('seqBlockUpdated')), 0)")
    $midiProcessor&.set_seq_editor_open(false)
    hide
  end

  def on_y_axis_change
    new_dim = @y_axis[:value].to_i
    @editor_notes.each do |note|
      y_val = 0
      if (note["c"] || 0) != 0
        y_val = note["c"]; note["c"] = 0
      elsif (note["d"] || 0) != 0
        y_val = note["d"]; note["d"] = 0
      elsif (note["e"] || 0) != 0
        y_val = note["e"]; note["e"] = 0
      end
      case new_dim
      when 3 then note["c"] = y_val
      when 4 then note["d"] = y_val
      when 5 then note["e"] = y_val
      end
    end
    sync_to_ruby
    render_lattice
  end

  def toggle_note(x, y)
    dim = @y_axis[:value].to_i
    idx = @editor_notes.find_index { |n| match_note?(n, x, y, dim) }
    if idx
      @editor_notes.delete_at(idx)
    else
      new_note = { "a" => 0, "b" => x, "c" => 0, "d" => 0, "e" => 0 }
      case dim
      when 3 then new_note["c"] = y
      when 4 then new_note["d"] = y
      when 5 then new_note["e"] = y
      end
      @editor_notes << new_note
      play_preview_note(new_note)
    end
    sync_to_ruby
    @editor_selected_cell = { x: x, y: y }
    render_lattice
  end

  def shift_octave(x, y, delta)
    dim = @y_axis[:value].to_i
    note = @editor_notes.find { |n| match_note?(n, x, y, dim) }
    if note
      note["a"] += delta
      play_preview_note(note)
    else
      new_note = { "a" => delta, "b" => x, "c" => 0, "d" => 0, "e" => 0 }
      case dim
      when 3 then new_note["c"] = y
      when 4 then new_note["d"] = y
      when 5 then new_note["e"] = y
      end
      @editor_notes << new_note
      play_preview_note(new_note)
    end
    sync_to_ruby
    @editor_selected_cell = { x: x, y: y }
    render_lattice
  end

  def match_note?(n, x, y, dim)
    return false unless (n["b"] || 0) == x
    case dim
    when 3 then (n["c"] || 0) == y
    when 4 then (n["d"] || 0) == y
    when 5 then (n["e"] || 0) == y
    else false
    end
  end

  def play_preview_note(note)
    a = note["a"] || 0; b = note["b"] || 0
    c = note["c"] || 0; d = note["d"] || 0; e = note["e"] || 0
    freq = $sequencer.calculate_freq_from_coords(a, b, c, d, e).to_f
    now = JS.global[:App][:audioCtx][:currentTime].to_f
    $previewSynth.schedule_note(freq, now, 0.3)
  rescue => e
    puts "[ChordSelectorModal] preview error: #{e.message}"
  end

  def sync_to_ruby
    $midiProcessor.set_seq_notes(@editor_notes.to_json)
    $midiProcessor.set_seq_dimension(@y_axis[:value].to_i)
  rescue => _
  end

  def render_lattice
    @lattice[:innerHTML] = ""
    dim = @y_axis[:value].to_i

    (2).downto(-2) do |y|
      (-4).upto(4) do |x|
        cell = create_div(
          background: "#222", color: "#fff", display: "flex",
          alignItems: "center", justifyContent: "center", aspectRatio: "1 / 1",
          cursor: "pointer", fontSize: "0.8rem", border: "1px solid #333", userSelect: "none"
        )

        if @editor_selected_cell[:x] == x && @editor_selected_cell[:y] == y
          cell[:style][:borderColor] = "#fff"
          cell[:style][:boxShadow] = "inset 0 0 0 2px #fff"
          cell[:style][:zIndex] = "10"
        end

        note = @editor_notes.find { |n| match_note?(n, x, y, dim) }
        if note
          if x == 0 && y == 0
            cell[:style][:background] = "#fff"
            cell[:style][:color] = "#000"
          elsif y == 0
            cell[:style][:background] = DIMENSION_COLORS[2]
          else
            cell[:style][:background] = DIMENSION_COLORS[dim]
          end
          a = note["a"] || 0
          if a > 0
            cell[:textContent] = "↑#{a}"
          elsif a < 0
            cell[:textContent] = "↓#{a.abs}"
          end
        end

        cx = x; cy = y
        cell.call(:addEventListener, "mousedown", proc { |e| begin_drag(e, cell, cx, cy) })

        @lattice.call(:appendChild, cell)
      end
    end
  end

  def begin_drag(event, cell, x, y)
    event.call(:preventDefault)
    dim = @y_axis[:value].to_i
    cell_note = @editor_notes.find { |n| match_note?(n, x, y, dim) }
    @drag_state = {
      cell: cell, x: x, y: y,
      start_y: event[:clientY].to_f,
      base_a: cell_note ? (cell_note["a"] || 0) : 0,
      has_note: !!cell_note,
      delta: 0
    }
    rid = @element[:__rubyId].to_s
    JS.eval(<<~JS)
      (() => {
        const onMove = (e) => {
          window._dragClientY = e.clientY;
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].on_drag_move(JS.global[:_dragClientY].to_f)"); } catch(_) {}
          delete window._dragClientY;
        };
        const onUp = () => {
          window.removeEventListener("mousemove", onMove);
          window.removeEventListener("mouseup", onUp);
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].on_drag_end"); } catch(_) {}
        };
        window.addEventListener("mousemove", onMove);
        window.addEventListener("mouseup", onUp);
      })();
    JS
  end

  def render_chord_list
    @list_el[:innerHTML] = ""
    chords = JSON.parse($chordManager.get_chords)
    if chords.empty?
      placeholder = create_div(
        textAlign: "center", color: "#aaa", padding: "20px"
      )
      placeholder[:style][:gridColumn] = "1/-1"
      placeholder[:textContent] = "No saved chords. Use the editor above or create chords in the Chord tab."
      @list_el.call(:appendChild, placeholder)
      return
    end

    chords.each do |name, entry|
      legacy = entry.is_a?(Array)
      notes = legacy ? entry : entry["notes"]
      dim = legacy ? nil : entry["dimension"]

      item = create_div(
        background: "#444", padding: "5px", borderRadius: "4px",
        cursor: "pointer", textAlign: "center"
      )
      item.call(:setAttribute, "data-chord", name)

      cvs = @doc.call(:createElement, "canvas")
      cvs[:width] = 80
      cvs[:height] = 80
      draw_tetris_shape(cvs.call(:getContext, "2d"), notes, 80, 80, dim)
      item.call(:appendChild, cvs)

      lbl = create_div(marginTop: "5px", fontSize: "0.9rem")
      lbl[:textContent] = name
      item.call(:appendChild, lbl)

      cap_notes = notes
      cap_dim = dim
      cap_item = item

      item.call(:addEventListener, "click", proc {
        @editor_notes = JSON.parse(cap_notes.to_json)
        @editor_selected_cell = { x: 0, y: 0 }

        if cap_dim
          @y_axis[:value] = cap_dim.to_s
        else
          inferred = 3
          inferred = 5 if @editor_notes.any? { |n| (n["e"] || 0) != 0 }
          inferred = 4 if inferred == 3 && @editor_notes.any? { |n| (n["d"] || 0) != 0 }
          @y_axis[:value] = inferred.to_s
        end

        sync_to_ruby
        render_lattice

        # highlight selected
        existing = @list_el.call(:querySelectorAll, "[data-chord]")
        len = existing[:length].to_i
        len.times do |i|
          existing.call(:item, i)[:style][:outline] = "none"
        end
        cap_item[:style][:outline] = "2px solid #28a745"
      })

      @list_el.call(:appendChild, item)
    end
  end

  def draw_tetris_shape(ctx, notes, w, h, dimension)
    ctx[:fillStyle] = "#222"
    ctx.call(:fillRect, 0, 0, w, h)
    return if notes.nil? || notes.empty?

    dim_to_use = dimension
    if dim_to_use.nil?
      dim_to_use = 3
      has5 = notes.any? { |n| (n["e"] || n[:e] || 0) != 0 }
      has4 = notes.any? { |n| (n["d"] || n[:d] || 0) != 0 }
      dim_to_use = 5 if has5
      dim_to_use = 4 if !has5 && has4
    end

    coords = notes.map do |n|
      yv = case dim_to_use
           when 4 then n["d"] || n[:d] || 0
           when 5 then n["e"] || n[:e] || 0
           else n["c"] || n[:c] || 0
           end
      { x: n["b"] || n[:b] || 0, y: yv }
    end

    min_x = coords.map { |p| p[:x] }.min
    max_x = coords.map { |p| p[:x] }.max
    min_y = coords.map { |p| p[:y] }.min
    max_y = coords.map { |p| p[:y] }.max

    range_x = max_x - min_x + 1
    range_y = max_y - min_y + 1
    cell_size = [w / (range_x + 1.0), h / (range_y + 1.0), 8].min
    offset_x = (w - range_x * cell_size) / 2.0 - min_x * cell_size
    offset_y = (h - range_y * cell_size) / 2.0

    coords.each do |p|
      cx = offset_x + p[:x] * cell_size
      cy = offset_y + (max_y - p[:y]) * cell_size

      if p[:x] == 0 && p[:y] == 0
        ctx[:fillStyle] = "#ffffff"
      elsif p[:y] == 0
        ctx[:fillStyle] = DIMENSION_COLORS[2]
      else
        ctx[:fillStyle] = DIMENSION_COLORS[dim_to_use]
      end

      if p[:x] == 0 && p[:y] == 0
        ctx.call(:beginPath)
        ctx.call(:arc, cx + cell_size / 2.0, cy + cell_size / 2.0, cell_size / 2.0 - 1, 0, Math::PI * 2)
        ctx.call(:fill)
        ctx[:strokeStyle] = "white"
        ctx[:lineWidth] = 1
        ctx.call(:stroke)
      else
        ctx.call(:beginPath)
        ctx.call(:roundRect, cx + 0.5, cy + 1, cell_size - 1, cell_size - 2, 2)
        ctx.call(:fill)
      end
    end
  end

  def create_div(**styles)
    el = @doc.call(:createElement, "div")
    style(el, **styles) unless styles.empty?
    el
  end

  def style(el, **styles)
    s = el[:style]
    styles.each { |k, v| s[k] = v }
  end

  ChordSelectorModal.register("chord-selector-modal")
end
