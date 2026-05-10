require 'js'
require 'json'
require 'web_component'

class ChordEditor
  include WebComponent

  DIMENSION_COLORS = {
    1 => "#ffffff",
    2 => "#ff7f50",
    3 => "#20b2aa",
    4 => "#9370db",
    5 => "#ffc247",
    6 => "#ffd700",
    7 => "#cd5c5c"
  }

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]

    @current_chord_name = ""
    @current_chord_notes = []
    @selected_cell = { x: 0, y: 0 }
    @drag_state = nil

    build_dom
    refresh_preview_presets
    render_chord_list
    render_editor

    install_global_event_listeners
  end

  def build_dom
    style_host

    # Left panel: saved chords list
    left = create_div(display: "flex", flexDirection: "column", overflow: "hidden")
    left[:className] = "panel"

    head_row = create_div(
      display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "10px"
    )
    title = @doc.call(:createElement, "h2")
    title[:textContent] = "Saved Chords"
    head_row.call(:appendChild, title)

    @create_btn = @doc.call(:createElement, "button")
    @create_btn[:textContent] = "+ New"
    style(@create_btn,
      padding: "5px 10px", background: "#28a745", color: "white", border: "none",
      cursor: "pointer", borderRadius: "4px"
    )
    head_row.call(:appendChild, @create_btn)
    left.call(:appendChild, head_row)

    @list_el = create_div(
      flexGrow: "1", overflowY: "auto", display: "flex", flexDirection: "column", gap: "5px"
    )
    left.call(:appendChild, @list_el)

    @element.call(:appendChild, left)

    # Right panel: editor
    right = create_div(display: "flex", flexDirection: "column")
    right[:className] = "panel"

    edit_row = create_div(
      display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "10px"
    )

    @name_input = @doc.call(:createElement, "input")
    @name_input[:type] = "text"
    @name_input.call(:setAttribute, "placeholder", "Chord Name")
    style(@name_input,
      padding: "8px", fontSize: "1rem", borderRadius: "4px", border: "1px solid #555",
      background: "#444", color: "white"
    )
    edit_row.call(:appendChild, @name_input)

    btns = create_div(display: "flex", gap: "10px", alignItems: "center")
    @preview_sel = @doc.call(:createElement, "select")
    @preview_sel[:style][:maxWidth] = "150px"
    btns.call(:appendChild, @preview_sel)

    @preview_btn = @doc.call(:createElement, "button")
    @preview_btn[:textContent] = "Preview"
    style(@preview_btn,
      padding: "8px 15px", background: "#17a2b8", color: "white", border: "none",
      cursor: "pointer", borderRadius: "4px"
    )
    btns.call(:appendChild, @preview_btn)

    @save_btn = @doc.call(:createElement, "button")
    @save_btn[:textContent] = "Save"
    style(@save_btn,
      padding: "8px 20px", background: "#007bff", color: "white", border: "none",
      cursor: "pointer", borderRadius: "4px"
    )
    btns.call(:appendChild, @save_btn)

    edit_row.call(:appendChild, btns)
    right.call(:appendChild, edit_row)

    # Y-axis dimension select
    ctrl_grp = create_div
    ctrl_grp[:className] = "control-group"
    y_label = @doc.call(:createElement, "label")
    y_label[:textContent] = "Y-Axis Dimension"
    ctrl_grp.call(:appendChild, y_label)
    @y_axis = @doc.call(:createElement, "select")
    [[3, "3rd Dim (5/4)"], [4, "4th Dim (7/4)"], [5, "5th Dim (11/4)"]].each do |val, text|
      opt = @doc.call(:createElement, "option")
      opt[:value] = val.to_s
      opt[:textContent] = text
      @y_axis.call(:appendChild, opt)
    end
    ctrl_grp.call(:appendChild, @y_axis)
    right.call(:appendChild, ctrl_grp)

    # Editor grid
    @grid = create_div(
      display: "grid", gridTemplateColumns: "repeat(9, 1fr)", gap: "2px",
      background: "#555", padding: "2px", flexGrow: "0", maxWidth: "600px",
      margin: "0 auto", width: "100%"
    )
    right.call(:appendChild, @grid)

    hint = @doc.call(:createElement, "p")
    hint[:innerHTML] = "Click to toggle note. <strong>Arrow Keys</strong> to shift selection."
    style(hint, textAlign: "center", color: "#888", fontSize: "0.9rem", marginTop: "10px")
    right.call(:appendChild, hint)

    @element.call(:appendChild, right)

    bind_events
  end

  def bind_events
    @name_input.call(:addEventListener, "keydown", proc { |e| e.call(:stopPropagation) })
    @preview_btn.call(:addEventListener, "click", proc { on_preview })
    @preview_sel.call(:addEventListener, "change", proc { |e| on_preview_select(e) })
    @create_btn.call(:addEventListener, "click", proc { on_create })
    @save_btn.call(:addEventListener, "click", proc { on_save })
    @y_axis.call(:addEventListener, "change", proc { on_y_axis_change })
  end

  def on_preview
    return if @current_chord_notes.empty?
    now = JS.global[:App][:audioCtx][:currentTime].to_f
    @current_chord_notes.each do |note|
      freq = $sequencer.calculate_freq_from_coords(
        note["a"] || note[:a], note["b"] || note[:b],
        note["c"] || note[:c], note["d"] || note[:d], note["e"] || note[:e]
      ).to_f
      $previewSynth.schedule_note(freq, now, 0.5)
    end
  rescue => e
    puts "[ChordEditor] preview error: #{e.message}"
  end

  def on_preview_select(event)
    name = event[:target][:value].to_s
    return if name.empty?
    presets = JSON.parse($presets.get_presets)
    json = presets[name]
    return unless json
    data = JSON.parse(json)
    if data["nodes"]
      $previewSynth.import_patch(json)
    else
      puts "[ChordEditor] legacy preset format not supported in preview"
    end
  rescue => e
    puts "[ChordEditor] preview select error: #{e.message}"
  end

  def on_create
    @current_chord_name = ""
    @current_chord_notes = []
    @selected_cell = { x: 0, y: 0 }
    @name_input[:value] = ""
    sync_to_ruby
    render_editor
  end

  def on_save
    name = @name_input[:value].to_s.strip
    if name.empty?
      JS.global.call(:alert, "Please enter a chord name.")
      return
    end
    if @current_chord_notes.empty?
      JS.global.call(:alert, "Chord is empty.")
      return
    end
    dim = @y_axis[:value].to_i
    notes_copy = JSON.parse(@current_chord_notes.to_json)
    $chordManager.update_chord(name, { "notes" => notes_copy, "dimension" => dim })
    JS.eval("setTimeout(() => window.dispatchEvent(new Event('chordsUpdated')), 0)")
    render_chord_list
    JS.global.call(:alert, "Chord \"#{name}\" saved!")
  end

  def on_y_axis_change
    new_dim = @y_axis[:value].to_i
    @current_chord_notes.each do |note|
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
    render_editor
  end

  def refresh_preview_presets
    @preview_sel[:innerHTML] = ""
    placeholder = @doc.call(:createElement, "option")
    placeholder[:value] = ""
    placeholder[:textContent] = "-- Preview Sound --"
    @preview_sel.call(:appendChild, placeholder)

    presets = JSON.parse($presets.get_presets)
    presets.keys.each do |name|
      opt = @doc.call(:createElement, "option")
      opt[:value] = name
      opt[:textContent] = name
      @preview_sel.call(:appendChild, opt)
    end
  end

  def render_chord_list
    @list_el[:innerHTML] = ""
    chords = JSON.parse($chordManager.get_chords)
    chords.each do |name, entry|
      legacy = entry.is_a?(Array)
      notes = legacy ? entry : entry["notes"]
      dim = legacy ? nil : entry["dimension"]

      item = create_div(
        background: "#444", padding: "5px", borderRadius: "4px", cursor: "pointer",
        display: "flex", alignItems: "center", gap: "10px"
      )

      canvas = @doc.call(:createElement, "canvas")
      canvas[:width] = 40
      canvas[:height] = 40
      draw_tetris_shape(canvas.call(:getContext, "2d"), notes, 40, 40, dim)

      label = @doc.call(:createElement, "span")
      label[:textContent] = name
      label[:style][:flexGrow] = "1"

      del_btn = @doc.call(:createElement, "span")
      del_btn[:className] = "material-icons"
      del_btn[:textContent] = "delete"
      style(del_btn, fontSize: "1rem", color: "#aaa")

      cap_name = name
      cap_notes = notes
      cap_dim = dim

      del_btn.call(:addEventListener, "click", proc { |e|
        e.call(:stopPropagation)
        confirmed = JS.global.call(:confirm, "Delete chord \"#{cap_name}\"?").to_s == "true"
        if confirmed
          $chordManager.delete_chord(cap_name)
          JS.eval("setTimeout(() => window.dispatchEvent(new Event('chordsUpdated')), 0)")
          render_chord_list
        end
      })

      item.call(:addEventListener, "click", proc {
        @current_chord_name = cap_name
        @current_chord_notes = JSON.parse(cap_notes.to_json)
        @selected_cell = { x: 0, y: 0 }

        if cap_dim
          @y_axis[:value] = cap_dim.to_s
        else
          inferred = 3
          inferred = 5 if @current_chord_notes.any? { |n| (n["e"] || 0) != 0 }
          inferred = 4 if @current_chord_notes.any? { |n| (n["d"] || 0) != 0 } && inferred == 3
          @y_axis[:value] = inferred.to_s
        end

        @name_input[:value] = cap_name
        sync_to_ruby
        render_editor
      })

      item.call(:appendChild, canvas)
      item.call(:appendChild, label)
      item.call(:appendChild, del_btn)
      @list_el.call(:appendChild, item)
    end
  end

  def render_editor
    render_lattice(@grid, @current_chord_notes, @y_axis[:value].to_i, @selected_cell)
  end

  def toggle_note(x, y)
    dim = @y_axis[:value].to_i
    idx = @current_chord_notes.find_index { |n| match_note?(n, x, y, dim) }
    if idx
      @current_chord_notes.delete_at(idx)
    else
      new_note = { "a" => 0, "b" => x, "c" => 0, "d" => 0, "e" => 0 }
      case dim
      when 3 then new_note["c"] = y
      when 4 then new_note["d"] = y
      when 5 then new_note["e"] = y
      end
      @current_chord_notes << new_note
      play_preview_note(new_note)
    end
    sync_to_ruby
    @selected_cell = { x: x, y: y }
    render_editor
  end

  def shift_octave(x, y, delta)
    dim = @y_axis[:value].to_i
    note = @current_chord_notes.find { |n| match_note?(n, x, y, dim) }
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
      @current_chord_notes << new_note
      play_preview_note(new_note)
    end
    sync_to_ruby
    @selected_cell = { x: x, y: y }
    render_editor
  end

  def re_render_chord
    json = $midiProcessor.get_chord_notes_json
    @current_chord_notes = JSON.parse(json)
    render_editor
  rescue => e
    puts "[ChordEditor] re_render_chord error: #{e.message}"
  end

  def set_chord_dimension(dim)
    @y_axis[:value] = dim.to_s
  end

  def handle_keydown(key)
    case key
    when " "
      toggle_note(@selected_cell[:x], @selected_cell[:y])
      true
    when "+", "="
      shift_selected_octave(1)
      true
    when "-"
      shift_selected_octave(-1)
      true
    when "ArrowUp"    then move_selection(0, 1); true
    when "ArrowDown"  then move_selection(0, -1); true
    when "ArrowLeft"  then move_selection(-1, 0); true
    when "ArrowRight" then move_selection(1, 0); true
    else
      false
    end
  end

  private

  def match_note?(n, x, y, dim)
    return false unless (n["b"] || 0) == x
    case dim
    when 3 then (n["c"] || 0) == y
    when 4 then (n["d"] || 0) == y
    when 5 then (n["e"] || 0) == y
    else false
    end
  end

  def shift_selected_octave(delta)
    dim = @y_axis[:value].to_i
    note = @current_chord_notes.find { |n| match_note?(n, @selected_cell[:x], @selected_cell[:y], dim) }
    if note
      note["a"] += delta
      play_preview_note(note)
      render_editor
    end
  end

  def move_selection(dx, dy)
    nx = @selected_cell[:x] + dx
    ny = @selected_cell[:y] + dy
    nx = -4 if nx < -4
    nx = 4 if nx > 4
    ny = -2 if ny < -2
    ny = 2 if ny > 2
    @selected_cell = { x: nx, y: ny }
    render_editor
  end

  def play_preview_note(note)
    a = note["a"] || note[:a] || 0
    b = note["b"] || note[:b] || 0
    c = note["c"] || note[:c] || 0
    d = note["d"] || note[:d] || 0
    e = note["e"] || note[:e] || 0
    freq = $sequencer.calculate_freq_from_coords(a, b, c, d, e).to_f
    now = JS.global[:App][:audioCtx][:currentTime].to_f
    $previewSynth.schedule_note(freq, now, 0.3)
  rescue => e
    puts "[ChordEditor] play_preview_note error: #{e.message}"
  end

  def sync_to_ruby
    $midiProcessor.set_chord_notes(@current_chord_notes.to_json)
    $midiProcessor.set_chord_dimension(@y_axis[:value].to_i)
  rescue => _
  end

  def render_lattice(container, notes, dim, selected_cell)
    container[:innerHTML] = ""

    (2).downto(-2) do |y|
      (-4).upto(4) do |x|
        cell = create_div(
          background: "#222", color: "#fff", display: "flex",
          alignItems: "center", justifyContent: "center", aspectRatio: "1 / 1",
          cursor: "pointer", fontSize: "0.8rem", border: "1px solid #333", userSelect: "none"
        )

        if selected_cell && selected_cell[:x] == x && selected_cell[:y] == y
          cell[:style][:borderColor] = "#fff"
          cell[:style][:boxShadow] = "inset 0 0 0 2px #fff"
          cell[:style][:zIndex] = "10"
        end

        note = notes.find { |n| match_note?(n, x, y, dim) }

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

        cell_x = x
        cell_y = y
        cell.call(:addEventListener, "mousedown", proc { |e| begin_cell_drag(e, cell, cell_x, cell_y) })

        container.call(:appendChild, cell)
      end
    end
  end

  def begin_cell_drag(event, cell, x, y)
    event.call(:preventDefault)
    dim = @y_axis[:value].to_i
    cell_note = @current_chord_notes.find { |n| match_note?(n, x, y, dim) }

    @drag_state = {
      cell: cell, x: x, y: y,
      start_y: event[:clientY].to_f,
      base_a: cell_note ? (cell_note["a"] || 0) : 0,
      has_note: !!cell_note,
      delta: 0
    }

    win = JS.global[:window]
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

  public

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
      cell[:textContent] = @drag_state[:has_note] ? "" : ""
    end
  end

  def on_drag_end
    return unless @drag_state
    x = @drag_state[:x]
    y = @drag_state[:y]
    delta = @drag_state[:delta]
    @drag_state = nil
    if delta != 0
      shift_octave(x, y, delta)
    else
      toggle_note(x, y)
    end
  end

  private

  def style_host
    s = @element[:style]
    s[:display] = "grid"
    s[:gridTemplateColumns] = "300px 1fr"
    s[:gap] = "20px"
    s[:height] = "100%"
    s[:width] = "100%"
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

  def draw_tetris_shape(ctx, notes, w, h, dimension)
    ctx[:fillStyle] = "#222"
    ctx.call(:fillRect, 0, 0, w, h)
    return if notes.nil? || notes.empty?

    dim_to_use = dimension
    if dim_to_use.nil?
      dim_to_use = 3
      has5 = notes.any? { |n| (n["e"] || 0) != 0 }
      has4 = notes.any? { |n| (n["d"] || 0) != 0 }
      dim_to_use = 5 if has5
      dim_to_use = 4 if !has5 && has4
    end

    coords = notes.map do |n|
      yv = case dim_to_use
           when 4 then n["d"] || 0
           when 5 then n["e"] || 0
           else n["c"] || 0
           end
      { x: n["b"] || 0, y: yv }
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

  def install_global_event_listeners
    rid = @element[:__rubyId].to_s
    JS.global[:__wcChordHost] = @element
    JS.eval(<<~JS)
      (() => {
        const host = window.__wcChordHost;
        const opts = host.__abort ? { signal: host.__abort.signal } : undefined;

        window.addEventListener("presetsUpdated", () => {
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].refresh_preview_presets"); } catch(_) {}
        }, opts);
        window.addEventListener("chordsUpdated", () => {
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].render_chord_list"); } catch(_) {}
        }, opts);
        window.addEventListener("keydown", (e) => {
          const view = document.getElementById("view-chord");
          if (!view || !view.classList.contains("active")) return;
          const tag = e.target && e.target.tagName;
          if (tag === "INPUT" || tag === "TEXTAREA") return;
          window._chordKey = e.key;
          let handled = false;
          try {
            handled = App.eval("WebComponent::WC_REGISTRY[#{rid}].handle_keydown(JS.global[:_chordKey].to_s)").toJS();
          } catch(_) {}
          delete window._chordKey;
          if (handled) e.preventDefault();
        }, opts);
      })();
    JS
    JS.global.call(:eval, "delete window.__wcChordHost")
  end

  ChordEditor.register("chord-editor")
end
