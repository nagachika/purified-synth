require 'js'
require 'web_component'

class SequencerControls
  include WebComponent

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]
    @last_is_playing = nil

    style_host
    build_dom
    sync_from_state
    install_play_state_polling
    install_global_event_listeners
  end

  # Called by sequencer_ui.js after a track-changed event so the slider values
  # follow project-load / external state changes.
  def sync_from_state
    return unless $sequencer

    bars = [1, ($sequencer.total_steps.to_i / 32)].max
    set_input(@measures_input, @measures_display, bars.to_s, bars.to_s) if bars.to_s != @measures_input[:value].to_s

    bpm_val = $sequencer.bpm.to_i
    set_input(@bpm_input, @bpm_display, bpm_val.to_s, bpm_val.to_s) if bpm_val.to_s != @bpm_input[:value].to_s

    swing_val = $sequencer.swing_amount.to_f
    if swing_val.to_s != @swing_input[:value].to_s
      @swing_input[:value] = swing_val.to_s
      @swing_display[:textContent] = (swing_val * 100).round.to_s
    end

    root_val = $sequencer.root_freq.to_f
    if root_val.to_s != @root_input[:value].to_s
      @root_input[:value] = root_val.to_s
    end
  rescue => e
    puts "[SequencerControls] sync error: #{e.message}"
  end

  def update_play_btn_ui
    return unless $sequencer
    is_playing = $sequencer.is_playing
    return if is_playing == @last_is_playing
    @last_is_playing = is_playing
    if is_playing
      @play_btn[:innerHTML] = '<span class="material-icons">stop</span> Stop'
      @play_btn[:style][:background] = "#dc3545"
    else
      @play_btn[:innerHTML] = '<span class="material-icons">play_arrow</span> Play'
      @play_btn[:style][:background] = "#007bff"
    end
  rescue => _
  end

  private

  def set_input(input, display, value, text)
    input[:value] = value
    display[:textContent] = text if display
  end

  def style_host
    s = @element[:style]
    s[:display] = "flex"
    s[:gap] = "20px"
    s[:alignItems] = "center"
    s[:marginBottom] = "20px"
    s[:flexWrap] = "wrap"
  end

  def build_dom
    @play_btn = @doc.call(:createElement, "button")
    @play_btn[:id] = "seq-play-btn"
    @play_btn[:innerHTML] = '<span class="material-icons">play_arrow</span> Play'
    style(@play_btn, padding: "10px 20px", fontSize: "1rem", display: "flex", alignItems: "center", gap: "5px")
    @play_btn.call(:addEventListener, "click", proc { on_play_toggle })
    @element.call(:appendChild, @play_btn)

    @add_track_btn = @doc.call(:createElement, "button")
    @add_track_btn[:id] = "add_track_btn"
    @add_track_btn[:innerHTML] = '<span class="material-icons">add</span> Melody Track'
    style(@add_track_btn, padding: "10px 15px", background: "#28a745", display: "flex", alignItems: "center", gap: "5px")
    @add_track_btn.call(:addEventListener, "click", proc { on_add_track })
    @element.call(:appendChild, @add_track_btn)

    @add_rhythm_btn = @doc.call(:createElement, "button")
    @add_rhythm_btn[:id] = "add_rhythm_track_btn"
    @add_rhythm_btn[:innerHTML] = '<span class="material-icons">add</span> Rhythm Track'
    style(@add_rhythm_btn, padding: "10px 15px", background: "#e03131", display: "flex", alignItems: "center", gap: "5px")
    @add_rhythm_btn.call(:addEventListener, "click", proc { on_add_rhythm_track })
    @element.call(:appendChild, @add_rhythm_btn)

    @measures_input, @measures_display = build_range_control(
      label: "Measures", value_id: "val_measures", input_id: "measures",
      min: "1", max: "64", step: "1", value: "4", default_text: "4"
    )
    @measures_input.call(:addEventListener, "input", proc { on_measures_input })

    @bpm_input, @bpm_display = build_range_control(
      label: "BPM", value_id: "val_bpm", input_id: "bpm",
      min: "60", max: "200", step: "1", value: "120", default_text: "120"
    )
    @bpm_input.call(:addEventListener, "input", proc { on_bpm_input })

    @swing_input, @swing_display = build_range_control(
      label: "Swing", value_id: "val_swing", input_id: "swing_amount",
      min: "0", max: "1", step: "0.1", value: "0", default_text: "0", min_width: "100px"
    )
    @swing_input.call(:addEventListener, "input", proc { on_swing_input })

    @master_vol_input, @master_vol_display = build_range_control(
      label: "Master Vol", value_id: "val_seq-master-volume", input_id: "seq-master-volume",
      min: "0", max: "1", step: "0.01", value: "1.0", default_text: "1.00"
    )
    @master_vol_input.call(:addEventListener, "input", proc { on_master_volume_input })

    # Root Freq is a number input, not a slider
    root_group = @doc.call(:createElement, "div")
    root_group[:className] = "control-group"
    style(root_group, marginBottom: "0", flexGrow: "1", minWidth: "150px")
    root_label = @doc.call(:createElement, "label")
    root_label[:textContent] = "Root Freq (Hz)"
    root_group.call(:appendChild, root_label)
    @root_input = @doc.call(:createElement, "input")
    @root_input[:id] = "root_freq"
    @root_input[:type] = "number"
    @root_input[:value] = "261.63"
    @root_input.call(:setAttribute, "step", "0.01")
    style(@root_input, width: "100%", padding: "5px", background: "#444", color: "white", border: "1px solid #555", borderRadius: "4px")
    @root_input.call(:addEventListener, "change", proc { on_root_freq_change })
    root_group.call(:appendChild, @root_input)
    @element.call(:appendChild, root_group)
  end

  def build_range_control(label:, value_id:, input_id:, min:, max:, step:, value:, default_text:, min_width: "150px")
    group = @doc.call(:createElement, "div")
    group[:className] = "control-group"
    style(group, marginBottom: "0", flexGrow: "1", minWidth: min_width)

    label_el = @doc.call(:createElement, "label")
    label_el[:textContent] = "#{label} "
    display = @doc.call(:createElement, "span")
    display[:id] = value_id
    display[:className] = "value-display"
    display[:textContent] = default_text
    label_el.call(:appendChild, display)
    group.call(:appendChild, label_el)

    input = @doc.call(:createElement, "input")
    input[:id] = input_id
    input[:type] = "range"
    input.call(:setAttribute, "min", min)
    input.call(:setAttribute, "max", max)
    input.call(:setAttribute, "step", step)
    input[:value] = value
    group.call(:appendChild, input)

    @element.call(:appendChild, group)
    [input, display]
  end

  def on_play_toggle
    return unless $sequencer
    if $sequencer.is_playing
      $sequencer.stop
    else
      $sequencer.start
    end
  rescue => e
    puts "[SequencerControls] play error: #{e.message}"
  end

  def on_add_track
    $sequencer.add_track
    notify_track_changed
  rescue => e
    puts "[SequencerControls] add_track error: #{e.message}"
  end

  def on_add_rhythm_track
    $sequencer.add_rhythm_track
    notify_track_changed
  rescue => e
    puts "[SequencerControls] add_rhythm_track error: #{e.message}"
  end

  def on_measures_input
    val = @measures_input[:value].to_i
    @measures_display[:textContent] = val.to_s
    $sequencer.set_total_bars(val)
    notify_track_changed
  rescue => e
    puts "[SequencerControls] measures error: #{e.message}"
  end

  def on_bpm_input
    val = @bpm_input[:value].to_i
    @bpm_display[:textContent] = val.to_s
    $sequencer.set_bpm(val)
  end

  def on_swing_input
    val = @swing_input[:value].to_f
    @swing_display[:textContent] = (val * 100).round.to_s
    $sequencer.set_swing_amount(val)
  end

  def on_root_freq_change
    val = @root_input[:value].to_f
    $sequencer.set_root_freq(val)
  end

  def on_master_volume_input
    val = @master_vol_input[:value].to_f
    @master_vol_display[:textContent] = format("%.2f", val)
    $sequencer.master_volume = val
    $previewSynth.volume = val if $previewSynth
    $chordSynth.volume = val if $chordSynth
  end

  def notify_track_changed
    JS.eval("setTimeout(() => window.dispatchEvent(new Event('seqTrackChanged')), 0)")
  end

  def install_play_state_polling
    rid = @element[:__rubyId].to_s
    JS.eval(<<~JS)
      setInterval(() => {
        try { App.eval("WebComponent::WC_REGISTRY[#{rid}].update_play_btn_ui"); } catch(_) {}
      }, 200);
    JS
  end

  def install_global_event_listeners
    rid = @element[:__rubyId].to_s
    JS.global[:__wcSeqCtlHost] = @element
    JS.eval(<<~JS)
      (() => {
        const host = window.__wcSeqCtlHost;
        const opts = host.__abort ? { signal: host.__abort.signal } : undefined;
        const refresh = () => {
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].sync_from_state"); } catch(_) {}
        };
        window.addEventListener("trackChanged", refresh, opts);
        window.addEventListener("seqTrackChanged", refresh, opts);
      })();
    JS
    JS.global.call(:eval, "delete window.__wcSeqCtlHost")
  end

  def style(el, **styles)
    s = el[:style]
    styles.each { |k, v| s[k] = v }
  end

  SequencerControls.register("sequencer-controls")
end
