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

    @container   = @doc.call(:getElementById, "pattern-editor-container")
    @list_el     = @doc.call(:getElementById, "pattern-list")
    @new_btn     = @doc.call(:getElementById, "new-pattern-btn")
    @name_input  = @doc.call(:getElementById, "pattern-name")
    @play_btn    = @doc.call(:getElementById, "pattern-play-btn")
    @bpm_input   = @doc.call(:getElementById, "pattern-bpm")
    @bpm_display = @doc.call(:getElementById, "pattern-val-bpm")

    @current_pattern_id = nil
    @current_playhead_step = -1

    bind_events
    load_patterns
    update_pattern_list

    install_animation_loop
    install_preview_polling
    install_global_event_listeners
  end

  def bind_events
    @new_btn.call(:addEventListener, "click", proc { on_new_pattern })
    @name_input.call(:addEventListener, "change", proc { |_e| on_rename })
    @play_btn.call(:addEventListener, "click", proc { on_play_toggle })
    @bpm_input.call(:addEventListener, "input", proc { |e| on_bpm_input(e) })
  end

  def on_new_pattern
    name = JS.global.call(:prompt, "Enter pattern name:", "New Beat").to_s
    return if name.empty? || name == "null" || name == "undefined"
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
      placeholder = @doc.call(:createElement, "div")
      placeholder[:textContent] = "Select or create a pattern to edit."
      ps = placeholder[:style]
      ps[:color] = "#aaa"
      ps[:textAlign] = "center"
      ps[:padding] = "20px"
      @container.call(:appendChild, placeholder)
      return
    end

    pattern_data = JSON.parse($sequencer.get_pattern_events_json(@current_pattern_id))

    table = @doc.call(:createElement, "div")
    ts = table[:style]
    ts[:display] = "grid"
    ts[:gridTemplateColumns] = "100px repeat(#{STEPS}, 1fr)"
    ts[:gap] = "2px"
    ts[:background] = "#222"
    ts[:border] = "1px solid #444"
    ts[:padding] = "10px"

    # Empty corner
    table.call(:appendChild, @doc.call(:createElement, "div"))

    STEPS.times do |i|
      header = @doc.call(:createElement, "div")
      header[:className] = "step-header"
      header.call(:setAttribute, "data-step", i.to_s)
      header[:textContent] = (i + 1).to_s
      hs = header[:style]
      hs[:textAlign] = "center"
      hs[:fontSize] = "0.7rem"
      hs[:color] = "#888"
      hs[:fontWeight] = "bold" if i % 4 == 0
      table.call(:appendChild, header)
    end

    INSTRUMENTS.each do |inst|
      label = @doc.call(:createElement, "div")
      label[:textContent] = inst
      ls = label[:style]
      ls[:color] = "#ccc"
      ls[:display] = "flex"
      ls[:alignItems] = "center"
      ls[:paddingLeft] = "5px"
      ls[:fontSize] = "0.9rem"
      table.call(:appendChild, label)

      active_steps = pattern_data[inst] || {}

      STEPS.times do |i|
        cell = @doc.call(:createElement, "div")
        cell[:className] = "step-cell"
        cell.call(:setAttribute, "data-step", i.to_s)
        cs = cell[:style]
        cs[:height] = "30px"

        is_active = active_steps.key?(i.to_s)
        velocity = is_active ? active_steps[i.to_s].to_f : 0

        if is_active
          alpha = 0.5 + velocity * 0.5
          cs[:background] = "rgba(255, 135, 135, #{alpha})"
          cell[:title] = "Velocity: #{(velocity * 127).round}"
        else
          cs[:background] = i % 4 == 0 ? "#444" : "#333"
        end

        cs[:borderRadius] = "2px"
        cs[:cursor] = "pointer"
        cs[:border] = "1px solid #555"
        cs[:transition] = "border-color 0.1s, box-shadow 0.1s"

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
    @list_el[:innerHTML] = ""

    if @current_pattern_id && !patterns.find { |p| p["id"] == @current_pattern_id }
      @current_pattern_id = patterns.empty? ? nil : patterns[0]["id"]
    end
    if @current_pattern_id.nil? && !patterns.empty?
      @current_pattern_id = patterns[0]["id"]
    end

    patterns.each do |p|
      row = @doc.call(:createElement, "div")
      rs = row[:style]
      rs[:display] = "flex"
      rs[:alignItems] = "center"
      rs[:justifyContent] = "space-between"
      rs[:padding] = "5px"
      rs[:marginBottom] = "1px"
      rs[:background] = (p["id"] == @current_pattern_id) ? "#007bff" : "#333"
      rs[:cursor] = "pointer"

      name_span = @doc.call(:createElement, "span")
      name_span[:textContent] = p["name"]
      ns = name_span[:style]
      ns[:flexGrow] = "1"
      ns[:whiteSpace] = "nowrap"
      ns[:overflow] = "hidden"
      ns[:textOverflow] = "ellipsis"

      pid = p["id"]
      pname = p["name"]
      name_span.call(:addEventListener, "click", proc { load_pattern(pid) })

      del_btn = @doc.call(:createElement, "button")
      del_btn[:innerHTML] = "&times;"
      ds = del_btn[:style]
      ds[:background] = "transparent"
      ds[:border] = "none"
      ds[:color] = "#ffcccc"
      ds[:fontWeight] = "bold"
      ds[:cursor] = "pointer"
      ds[:padding] = "0 8px"
      ds[:fontSize] = "1.2rem"
      del_btn[:title] = "Delete Pattern"

      del_btn.call(:addEventListener, "click", proc { |e|
        e.call(:stopPropagation)
        confirmed = JS.global.call(:confirm, "Delete pattern \"#{pname}\"?").to_s == "true"
        if confirmed
          $sequencer.delete_pattern(pid)
          save_patterns
          update_pattern_list
        end
      })

      row.call(:appendChild, name_span)
      row.call(:appendChild, del_btn)
      @list_el.call(:appendChild, row)
    end

    if @current_pattern_id
      load_pattern(@current_pattern_id, false)
    else
      render_grid
    end
  end

  def load_pattern(id, refresh_list = true)
    @current_pattern_id = id
    name = ""
    patterns = JSON.parse($sequencer.get_patterns_json)
    p = patterns.find { |x| x["id"] == id }
    name = p["name"] if p
    @name_input[:value] = name

    if refresh_list
      update_pattern_list
    else
      render_grid
    end
  rescue => e
    puts "[PatternEditor] load_pattern error: #{e.message}"
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

  # rAF loop and polling are owned by JS so the Ruby VM is invoked from a single
  # JS-side scheduler, mirroring the original setupPatternEditor timing.
  def install_animation_loop
    rid = @element[:__rubyId].to_s
    JS.eval(<<~JS)
      (() => {
        function animate() {
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].update_highlight"); } catch(e) {}
          requestAnimationFrame(animate);
        }
        requestAnimationFrame(animate);
      })();
    JS
  end

  def install_preview_polling
    rid = @element[:__rubyId].to_s
    JS.eval(<<~JS)
      setInterval(() => {
        try { App.eval("WebComponent::WC_REGISTRY[#{rid}].update_preview_ui"); } catch(e) {}
      }, 200);
    JS
  end

  def install_global_event_listeners
    rid = @element[:__rubyId].to_s
    JS.eval(<<~JS)
      window.addEventListener("refreshPatterns", () => {
        try { App.eval("WebComponent::WC_REGISTRY[#{rid}].update_pattern_list"); } catch(e) {}
      });
      window.addEventListener("selectPattern", (e) => {
        if (e.detail && e.detail.id) {
          window._selectPatternId = e.detail.id;
          try {
            App.eval("WebComponent::WC_REGISTRY[#{rid}].load_pattern(JS.global[:_selectPatternId].to_s)");
          } catch(err) {}
          delete window._selectPatternId;
        }
      });
    JS
  end

  PatternEditor.register("pattern-editor")
end
