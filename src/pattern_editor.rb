require 'js'
require 'json'
require 'web_component'

class PatternEditor
  include WebComponent

  INSTRUMENTS = %w[Kick Snare HiHat OpenHat]
  STEPS = 16
  STORAGE_KEY = "ruby_synth_patterns"

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]

    @current_pattern_id = nil
    @current_playhead_step = -1

    build_dom
    load_patterns
    update_pattern_list

    install_animation_loop
    install_preview_polling
    install_global_event_listeners
  end

  def build_dom
    style_host

    # Left sidebar: pattern list + new pattern button
    sidebar = create_div(
      width: "250px", background: "#333", padding: "20px",
      borderRight: "1px solid #444", display: "flex", flexDirection: "column"
    )

    sidebar_title = @doc.call(:createElement, "h2")
    sidebar_title[:textContent] = "Patterns"
    style(sidebar_title, color: "#4dabf7", borderBottom: "1px solid #555", paddingBottom: "10px")
    sidebar.call(:appendChild, sidebar_title)

    @list_el = create_div(
      width: "100%", background: "#222", color: "white", border: "1px solid #555",
      marginBottom: "10px", flexGrow: "1", padding: "5px", overflowY: "auto"
    )
    sidebar.call(:appendChild, @list_el)

    @new_btn = @doc.call(:createElement, "button")
    @new_btn[:textContent] = "+ New Pattern"
    style(@new_btn,
      width: "100%", padding: "8px", background: "#007bff", color: "white",
      border: "none", cursor: "pointer", borderRadius: "4px", marginBottom: "10px"
    )
    sidebar.call(:appendChild, @new_btn)

    @element.call(:appendChild, sidebar)

    # Right main area: title + controls + grid
    main = create_div(flexGrow: "1", padding: "20px", display: "flex", flexDirection: "column")

    main_title = @doc.call(:createElement, "h2")
    main_title[:textContent] = "Pattern Editor"
    style(main_title, color: "#4dabf7")
    main.call(:appendChild, main_title)

    controls = create_div(display: "flex", gap: "10px", alignItems: "flex-end")
    controls[:className] = "control-group"

    # Name field
    name_wrap = create_div(flexGrow: "1")
    name_label = @doc.call(:createElement, "label")
    name_label[:textContent] = "Name"
    name_wrap.call(:appendChild, name_label)
    @name_input = @doc.call(:createElement, "input")
    @name_input[:type] = "text"
    style(@name_input,
      width: "100%", background: "#222", color: "white", border: "1px solid #555",
      padding: "5px", borderRadius: "4px"
    )
    name_wrap.call(:appendChild, @name_input)
    controls.call(:appendChild, name_wrap)

    # BPM
    bpm_wrap = create_div(width: "120px")
    bpm_label = @doc.call(:createElement, "label")
    bpm_label[:innerHTML] = 'BPM <span class="value-display"></span>'
    bpm_wrap.call(:appendChild, bpm_label)
    @bpm_display = bpm_label.call(:querySelector, ".value-display")
    @bpm_display[:textContent] = "120"
    @bpm_input = @doc.call(:createElement, "input")
    @bpm_input[:type] = "range"
    @bpm_input.call(:setAttribute, "min", "60")
    @bpm_input.call(:setAttribute, "max", "200")
    @bpm_input.call(:setAttribute, "step", "1")
    @bpm_input[:value] = "120"
    bpm_wrap.call(:appendChild, @bpm_input)
    controls.call(:appendChild, bpm_wrap)

    # Play button
    @play_btn = @doc.call(:createElement, "button")
    @play_btn[:innerHTML] = '<span class="material-icons">play_arrow</span> Preview'
    style(@play_btn,
      padding: "5px 15px", background: "#28a745", color: "white", border: "none",
      cursor: "pointer", borderRadius: "4px", display: "flex", alignItems: "center", height: "28px"
    )
    controls.call(:appendChild, @play_btn)

    main.call(:appendChild, controls)

    @container = create_div(flexGrow: "1", overflowY: "auto")
    main.call(:appendChild, @container)

    @element.call(:appendChild, main)

    bind_events
  end

  def bind_events
    @new_btn.call(:addEventListener, "click", proc { on_new_pattern })
    @name_input.call(:addEventListener, "change", proc { |_e| on_rename })
    @name_input.call(:addEventListener, "keydown", proc { |e| e.call(:stopPropagation) })
    @play_btn.call(:addEventListener, "click", proc { on_play_toggle })
    @bpm_input.call(:addEventListener, "input", proc { |e| on_bpm_input(e) })
  end

  def on_new_pattern
    result = JS.global.call(:prompt, "Enter pattern name:", "New Beat")
    return if result == JS::Null
    name = result.to_s
    return if name.empty?
    $sequencer.create_pattern(name)
    save_patterns
    patterns = JSON.parse($sequencer.get_patterns_json)
    last = patterns.last
    if last
      load_pattern(last["id"])
    else
      update_pattern_list
    end
  rescue => e
    puts "[PatternEditor] on_new_pattern error: #{e.message}"
  end

  def on_rename
    return unless @current_pattern_id
    new_name = @name_input[:value].to_s
    $sequencer.rename_pattern(@current_pattern_id, new_name)
    save_patterns
    update_pattern_list
  end

  def on_play_toggle
    return unless @current_pattern_id
    if $patternSequencer.is_playing
      $patternSequencer.stop
    else
      $patternSequencer.add_or_update_block(0, 0, 32, @current_pattern_id)
      $patternSequencer.start
    end
  rescue => e
    puts "[PatternEditor] on_play_toggle error: #{e.message}"
  end

  def on_bpm_input(event)
    val = event[:target][:value].to_i
    @bpm_display[:textContent] = val.to_s
    $patternSequencer.set_bpm(val)
  end

  def save_patterns
    json = $sequencer.export_patterns_json
    JS.global[:localStorage].call(:setItem, STORAGE_KEY, json)
  rescue => e
    puts "[PatternEditor] save_patterns error: #{e.message}"
  end

  def load_patterns
    raw = JS.global[:localStorage].call(:getItem, STORAGE_KEY).to_s
    return if raw.empty? || raw == "null"
    $sequencer.import_patterns_json(raw)
  rescue => e
    puts "[PatternEditor] load_patterns error: #{e.message}"
  end

  def render_grid
    @container[:innerHTML] = ""
    unless @current_pattern_id
      placeholder = create_div(color: "#aaa", textAlign: "center", padding: "20px")
      placeholder[:textContent] = "Select or create a pattern to edit."
      @container.call(:appendChild, placeholder)
      return
    end

    pattern_data = JSON.parse($sequencer.get_pattern_events_json(@current_pattern_id))

    table = create_div(
      display: "grid",
      gridTemplateColumns: "100px repeat(#{STEPS}, 1fr)",
      gap: "2px", background: "#222", border: "1px solid #444", padding: "10px"
    )

    # Empty corner
    table.call(:appendChild, @doc.call(:createElement, "div"))

    STEPS.times do |i|
      header = @doc.call(:createElement, "div")
      header[:className] = "step-header"
      header.call(:setAttribute, "data-step", i.to_s)
      header[:textContent] = (i + 1).to_s
      style(header, textAlign: "center", fontSize: "0.7rem", color: "#888")
      header[:style][:fontWeight] = "bold" if i % 4 == 0
      table.call(:appendChild, header)
    end

    INSTRUMENTS.each do |inst|
      label = create_div(
        color: "#ccc", display: "flex", alignItems: "center",
        paddingLeft: "5px", fontSize: "0.9rem"
      )
      label[:textContent] = inst
      table.call(:appendChild, label)

      active_steps = pattern_data[inst] || {}

      STEPS.times do |i|
        cell = @doc.call(:createElement, "div")
        cell[:className] = "step-cell"
        cell.call(:setAttribute, "data-step", i.to_s)

        is_active = active_steps.key?(i.to_s)
        velocity = is_active ? active_steps[i.to_s].to_f : 0

        bg = if is_active
               alpha = 0.5 + velocity * 0.5
               cell[:title] = "Velocity: #{(velocity * 127).round}"
               "rgba(255, 135, 135, #{alpha})"
             else
               i % 4 == 0 ? "#444" : "#333"
             end

        style(cell,
          height: "30px", background: bg, borderRadius: "2px", cursor: "pointer",
          border: "1px solid #555", transition: "border-color 0.1s, box-shadow 0.1s"
        )

        pid = @current_pattern_id
        instrument = inst
        step_idx = i
        cell.call(:addEventListener, "click", proc {
          $sequencer.toggle_pattern_step(pid, instrument, step_idx)
          save_patterns
          render_grid
        })

        table.call(:appendChild, cell)
      end
    end

    @container.call(:appendChild, table)
  end

  def update_pattern_list
    patterns = JSON.parse($sequencer.get_patterns_json)
    ensure_current_pattern(patterns)
    render_pattern_list(patterns)
    sync_name_input(patterns)
    render_grid
  end

  def load_pattern(id)
    @current_pattern_id = id
    update_pattern_list
  rescue => e
    puts "[PatternEditor] load_pattern error: #{e.message}"
  end

  # Called after the sequencer's patterns are swapped wholesale (e.g. project
  # load). Persists the new patterns to localStorage so a page reload doesn't
  # clobber them with the previous session, then refreshes the list/grid.
  def sync_patterns_from_sequencer
    save_patterns
    update_pattern_list
  rescue => e
    puts "[PatternEditor] sync_patterns_from_sequencer error: #{e.message}"
  end

  def update_preview_ui
    bpm = $patternSequencer.bpm.to_s
    if @doc[:activeElement] != @bpm_input
      @bpm_input[:value] = bpm
      @bpm_display[:textContent] = bpm
    end

    if $patternSequencer.is_playing
      @play_btn[:innerHTML] = '<span class="material-icons" style="font-size: 1.2rem; margin-right: 4px;">stop</span> Stop'
      @play_btn[:style][:background] = "#dc3545"
    else
      @play_btn[:innerHTML] = '<span class="material-icons" style="font-size: 1.2rem; margin-right: 4px;">play_arrow</span> Preview'
      @play_btn[:style][:background] = "#28a745"
    end
  rescue => e
    # silent: polled frequently
  end

  def update_highlight
    return unless @current_pattern_id

    is_playing = $patternSequencer.is_playing
    seq_step = is_playing ? JS.global[:_currentPreviewStep].to_i : -1
    pattern_step = seq_step >= 0 ? (seq_step % 32) / 2 : -1

    return if pattern_step == @current_playhead_step
    @current_playhead_step = pattern_step

    cells = @container.call(:querySelectorAll, ".step-cell")
    cells_len = cells[:length].to_i
    cells_len.times do |i|
      cell = cells.call(:item, i)
      step_idx = cell.call(:getAttribute, "data-step").to_i
      if step_idx == pattern_step
        cell[:style][:borderColor] = "#fff"
        cell[:style][:boxShadow] = "inset 0 0 5px #fff"
      else
        cell[:style][:borderColor] = "#555"
        cell[:style][:boxShadow] = "none"
      end
    end

    headers = @container.call(:querySelectorAll, ".step-header")
    headers_len = headers[:length].to_i
    headers_len.times do |i|
      h = headers.call(:item, i)
      step_idx = h.call(:getAttribute, "data-step").to_i
      h[:style][:color] = (step_idx == pattern_step) ? "#fff" : "#888"
      h[:style][:fontWeight] = (step_idx == pattern_step || step_idx % 4 == 0) ? "bold" : "normal"
    end
  rescue => e
    # silent: per-frame
  end

  private

  def ensure_current_pattern(patterns)
    if @current_pattern_id && !patterns.find { |p| p["id"] == @current_pattern_id }
      @current_pattern_id = patterns.empty? ? nil : patterns[0]["id"]
    end
    if @current_pattern_id.nil? && !patterns.empty?
      @current_pattern_id = patterns[0]["id"]
    end
  end

  def render_pattern_list(patterns)
    @list_el[:innerHTML] = ""

    patterns.each do |p|
      row = create_div(
        display: "flex", alignItems: "center", justifyContent: "space-between",
        padding: "5px", marginBottom: "1px",
        background: (p["id"] == @current_pattern_id) ? "#007bff" : "#333",
        cursor: "pointer"
      )

      name_span = @doc.call(:createElement, "span")
      name_span[:textContent] = p["name"]
      style(name_span,
        flexGrow: "1", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis"
      )

      pid = p["id"]
      pname = p["name"]
      name_span.call(:addEventListener, "click", proc { load_pattern(pid) })

      del_btn = @doc.call(:createElement, "button")
      del_btn[:innerHTML] = "&times;"
      style(del_btn,
        background: "transparent", border: "none", color: "#ffcccc",
        fontWeight: "bold", cursor: "pointer", padding: "0 8px", fontSize: "1.2rem"
      )
      del_btn[:title] = "Delete Pattern"

      del_btn.call(:addEventListener, "click", proc { |e|
        e.call(:stopPropagation)
        if JS.global.call(:confirm, "Delete pattern \"#{pname}\"?") == JS::True
          $sequencer.delete_pattern(pid)
          save_patterns
          update_pattern_list
        end
      })

      row.call(:appendChild, name_span)
      row.call(:appendChild, del_btn)
      @list_el.call(:appendChild, row)
    end
  end

  def sync_name_input(patterns)
    p = patterns.find { |x| x["id"] == @current_pattern_id }
    @name_input[:value] = p ? p["name"] : ""
  end

  def style_host
    s = @element[:style]
    s[:display] = "flex"
    s[:flexGrow] = "1"
    s[:width] = "100%"
    s[:height] = "100%"
  end

  def create_div(**styles)
    el = @doc.call(:createElement, "div")
    style(el, **styles)
    el
  end

  def style(el, **styles)
    s = el[:style]
    styles.each { |k, v| s[k] = v }
  end

  # rAF loop and polling are owned by JS so the Ruby VM is invoked from a single
  # JS-side scheduler, mirroring the original setupPatternEditor timing.
  # The AbortSignal owned by the WebComponent base stops them on disconnect.
  def install_animation_loop
    rid = @element[:__rubyId].to_i
    JS.global[:__wcSignal] = @element[:__abort][:signal]
    JS.eval(<<~JS)
      (() => {
        const signal = window.__wcSignal;
        delete window.__wcSignal;
        function animate() {
          if (signal.aborted) return;
          try { App.call("wc:#{rid}", "update_highlight"); } catch(e) {}
          requestAnimationFrame(animate);
        }
        requestAnimationFrame(animate);
      })();
    JS
  end

  def install_preview_polling
    rid = @element[:__rubyId].to_i
    JS.global[:__wcSignal] = @element[:__abort][:signal]
    JS.eval(<<~JS)
      (() => {
        const signal = window.__wcSignal;
        delete window.__wcSignal;
        const id = setInterval(() => {
          try { App.call("wc:#{rid}", "update_preview_ui"); } catch(e) {}
        }, 200);
        signal.addEventListener('abort', () => clearInterval(id));
      })();
    JS
  end

  def install_global_event_listeners
    rid = @element[:__rubyId].to_i
    JS.global[:__wcSignal] = @element[:__abort][:signal]
    JS.eval(<<~JS)
      (() => {
        const signal = window.__wcSignal;
        delete window.__wcSignal;
        window.addEventListener("refreshPatterns", () => {
          App.call("wc:#{rid}", "sync_patterns_from_sequencer");
        }, { signal });
        window.addEventListener("selectPattern", (e) => {
          if (e.detail && e.detail.id) {
            App.call("wc:#{rid}", "load_pattern", e.detail.id);
          }
        }, { signal });
      })();
    JS
  end

  PatternEditor.register("pattern-editor")
end
