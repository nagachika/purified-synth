require 'js'
require 'json'
require 'web_component'

class TrackControls
  include WebComponent

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]
    @track_idx = element.call(:getAttribute, "track-index").to_i
    @track_type = nil
    @preset_listeners_attached = false

    style_host
    build_dom
    refresh
    install_global_event_listeners
  end

  def refresh
    type = $sequencer.get_track_type(@track_idx).to_s

    if @track_type != type
      apply_type_change(type)
      @track_type = type
    end

    apply_selection
    apply_preset_value if type == "melodic"
    apply_mute
    apply_solo
    apply_send
    apply_arp(type)
    apply_volume
  end

  def refresh_preset_list
    return unless @track_type == "melodic"
    populate_preset_list
  end

  private

  def style_host
    s = @element[:style]
    s[:display] = "flex"
    s[:flexDirection] = "column"
    # Border-box width + gap must match TRACK_HEADER_WIDTH / TRACK_HEADER_GAP
    # in src/js/utils.js so marker/ruler/scroll spacers line up with the grid.
    s[:boxSizing] = "border-box"
    s[:width] = "190px"
    s[:flexShrink] = "0"
    s[:borderRight] = "1px solid #555"
    s[:paddingRight] = "10px"
    s[:marginRight] = "10px"
    s[:justifyContent] = "center"
    s[:gap] = "5px"
  end

  def build_dom
    @label_btn = @doc.call(:createElement, "button")
    style(@label_btn, padding: "4px", fontSize: "0.8rem", border: "1px solid #555", cursor: "pointer")
    @label_btn.call(:addEventListener, "click", proc { on_select })

    @preset_sel = @doc.call(:createElement, "select")
    style(@preset_sel, fontSize: "0.8rem", padding: "2px", width: "100%")

    btn_row = @doc.call(:createElement, "div")
    style(btn_row, display: "flex", gap: "2px")

    @remove_btn = @doc.call(:createElement, "button")
    @remove_btn[:innerHTML] = '<span class="material-icons" style="font-size: 1.2rem;">delete</span>'
    style(@remove_btn, padding: "4px", background: "#dc3545", color: "white", border: "none", cursor: "pointer")
    @remove_btn.call(:addEventListener, "click", proc { on_remove })
    btn_row.call(:appendChild, @remove_btn)

    @mute_btn = @doc.call(:createElement, "button")
    style(@mute_btn, padding: "4px", color: "white", border: "1px solid #555", cursor: "pointer")
    @mute_btn.call(:addEventListener, "click", proc { on_toggle_mute })
    btn_row.call(:appendChild, @mute_btn)

    @solo_btn = @doc.call(:createElement, "button")
    style(@solo_btn, padding: "4px", border: "1px solid #555", cursor: "pointer")
    @solo_btn.call(:addEventListener, "click", proc { on_toggle_solo })
    btn_row.call(:appendChild, @solo_btn)

    @send_btn = @doc.call(:createElement, "button")
    style(@send_btn, padding: "4px", border: "1px solid #555", cursor: "pointer")
    @send_btn[:title] = "Send to Effects"
    @send_btn.call(:addEventListener, "click", proc { on_toggle_send })
    btn_row.call(:appendChild, @send_btn)

    @arp_btn = @doc.call(:createElement, "button")
    style(@arp_btn, padding: "4px", border: "1px solid #555")
    @arp_btn.call(:addEventListener, "click", proc { on_toggle_arp })
    btn_row.call(:appendChild, @arp_btn)

    @knob_container = @doc.call(:createElement, "div")
    style(@knob_container,
      display: "flex", alignItems: "center", justifyContent: "center", cursor: "ns-resize"
    )
    @knob_container[:title] = "Volume"
    @knob_icon = @doc.call(:createElement, "span")
    @knob_icon[:className] = "material-icons"
    @knob_icon[:textContent] = "arrow_circle_up"
    style(@knob_icon, fontSize: "1.5rem", color: "#4dabf7")
    @knob_container.call(:appendChild, @knob_icon)
    @knob_container.call(:addEventListener, "mousedown", proc { |e| begin_volume_drag(e) })
    btn_row.call(:appendChild, @knob_container)

    @element.call(:appendChild, @label_btn)
    @element.call(:appendChild, @preset_sel)
    @element.call(:appendChild, btn_row)
  end

  def apply_type_change(type)
    emoji = type == "rhythmic" ? "🥁 " : "🎹 "
    @label_btn[:textContent] = "#{emoji}Track #{@track_idx + 1}"

    if type == "melodic"
      @preset_sel[:disabled] = false
      populate_preset_list
      attach_preset_listeners unless @preset_listeners_attached
      style(@arp_btn, cursor: "pointer", opacity: "1")
      @arp_btn[:title] = "Arpeggiator ON/OFF"
    else
      @preset_sel[:disabled] = true
      @preset_sel[:innerHTML] = "<option>Drum Kit</option>"
      style(@arp_btn, cursor: "default", opacity: "0.3")
      @arp_btn[:title] = ""
    end
  end

  def populate_preset_list
    current = @preset_sel[:value].to_s
    @preset_sel[:innerHTML] = ""
    placeholder = @doc.call(:createElement, "option")
    placeholder[:value] = ""
    placeholder[:textContent] = "(Default)"
    @preset_sel.call(:appendChild, placeholder)

    $presets.presets.keys.each do |name|
      opt = @doc.call(:createElement, "option")
      opt[:value] = name
      opt[:textContent] = name
      @preset_sel.call(:appendChild, opt)
    end

    @preset_sel[:value] = current unless current.empty?
  end

  def attach_preset_listeners
    @preset_sel.call(:addEventListener, "mousedown", proc {
      @preset_open = true
      @preset_prev_value = @preset_sel[:value].to_s
    })

    @preset_sel.call(:addEventListener, "change", proc { |e|
      @preset_open = false
      name = e[:target][:value].to_s
      apply_preset(name)
    })

    @preset_sel.call(:addEventListener, "blur", proc {
      if @preset_open
        @preset_open = false
        prev = @preset_prev_value.to_s
        curr = @preset_sel[:value].to_s
        apply_preset(curr) if prev == curr
      end
    })

    @preset_listeners_attached = true
  end

  def apply_preset(name)
    if name.empty?
      patch_json = $previewSynth.export_patch
      $sequencer.import_track_patch(@track_idx, patch_json)
      $sequencer.set_track_preset_name(@track_idx, "")
    else
      json = $presets.presets[name]
      if json
        $sequencer.import_track_patch(@track_idx, json)
        $sequencer.set_track_preset_name(@track_idx, name)
      end
    end
  rescue => e
    puts "[TrackControls] apply_preset error: #{e.message}"
  end

  def apply_selection
    if @track_idx == $sequencer.current_track_index
      @label_btn[:style][:background] = "#007bff"
      @label_btn[:style][:color] = "white"
    else
      @label_btn[:style][:background] = "#333"
      @label_btn[:style][:color] = "#ccc"
    end
  end

  def apply_preset_value
    return if @preset_open
    @preset_sel[:value] = $sequencer.get_track_preset_name(@track_idx).to_s
  end

  def apply_mute
    muted = $sequencer.get_track_mute(@track_idx)
    @mute_btn[:innerHTML] = "<span class=\"material-icons\" style=\"font-size: 1.2rem;\">#{muted ? 'volume_off' : 'volume_up'}</span>"
    @mute_btn[:style][:background] = muted ? "#6c757d" : "#444"
  end

  def apply_solo
    solo = $sequencer.get_track_solo(@track_idx)
    @solo_btn[:innerHTML] = "<span class=\"material-icons\" style=\"font-size: 1.2rem;\">#{solo ? 'grade' : 'star_outline'}</span>"
    @solo_btn[:style][:background] = solo ? "#fcc419" : "#444"
    @solo_btn[:style][:color] = solo ? "black" : "white"
  end

  def apply_send
    send = $sequencer.get_track_send(@track_idx)
    @send_btn[:innerHTML] = "<span class=\"material-icons\" style=\"font-size: 1.2rem;\">#{send ? 'blur_on' : 'blur_off'}</span>"
    @send_btn[:style][:background] = send ? "#be4bdb" : "#444"
    @send_btn[:style][:color] = send ? "white" : "#ccc"
  end

  def apply_arp(type)
    if type == "melodic"
      arp = $sequencer.get_arpeggiator_status(@track_idx)
      @arp_btn[:innerHTML] = "<span class=\"material-icons\" style=\"font-size: 1.2rem;\">#{arp ? 'clear_all' : 'dehaze'}</span>"
      @arp_btn[:style][:background] = arp ? "#4dabf7" : "#444"
      @arp_btn[:style][:color] = arp ? "white" : "#ccc"
    else
      @arp_btn[:innerHTML] = '<span class="material-icons" style="font-size: 1.2rem;">dehaze</span>'
      @arp_btn[:style][:background] = "#222"
      @arp_btn[:style][:color] = "#555"
    end
  end

  def apply_volume
    vol = $sequencer.get_track_volume(@track_idx).to_f
    @knob_icon[:style][:transform] = "rotate(#{(vol - 1.0) * 160}deg)"
  end

  def on_select
    $sequencer.select_track(@track_idx)
    notify_change
  end

  def on_remove
    confirmed = JS.global.call(:confirm, "Remove Track #{@track_idx + 1}?").to_s == "true"
    return unless confirmed
    $sequencer.remove_track(@track_idx)
    notify_change
  end

  def on_toggle_mute
    $sequencer.set_track_mute(@track_idx, !$sequencer.get_track_mute(@track_idx))
    notify_change
  end

  def on_toggle_solo
    $sequencer.set_track_solo(@track_idx, !$sequencer.get_track_solo(@track_idx))
    notify_change
  end

  def on_toggle_send
    $sequencer.set_track_send(@track_idx, !$sequencer.get_track_send(@track_idx))
    notify_change
  end

  def on_toggle_arp
    return unless @track_type == "melodic"
    $sequencer.set_arpeggiator_enabled(@track_idx, !$sequencer.get_arpeggiator_status(@track_idx))
    notify_change
  end

  def begin_volume_drag(event)
    start_y = event[:clientY].to_f
    start_vol = $sequencer.get_track_volume(@track_idx).to_f
    rid = @element[:__rubyId].to_s
    JS.global[:_volStartY] = start_y
    JS.global[:_volStartVol] = start_vol
    JS.eval(<<~JS)
      (() => {
        const startY = window._volStartY;
        const startVol = window._volStartVol;
        const onMove = (me) => {
          let nv = startVol + (startY - me.clientY) / 100;
          if (nv < 0) nv = 0;
          if (nv > 2) nv = 2;
          window._volNew = nv;
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].on_volume_drag(JS.global[:_volNew].to_f)"); } catch(_) {}
        };
        const onUp = () => {
          window.removeEventListener("mousemove", onMove);
          window.removeEventListener("mouseup", onUp);
          delete window._volStartY;
          delete window._volStartVol;
          delete window._volNew;
        };
        window.addEventListener("mousemove", onMove);
        window.addEventListener("mouseup", onUp);
      })();
    JS
  end

  public

  def on_volume_drag(value)
    $sequencer.set_track_volume(@track_idx, value)
    @knob_icon[:style][:transform] = "rotate(#{(value - 1.0) * 160}deg)"
  end

  private

  def notify_change
    JS.eval("setTimeout(() => window.dispatchEvent(new Event('seqTrackChanged')), 0)")
  end

  def install_global_event_listeners
    rid = @element[:__rubyId].to_s
    JS.global[:__wcTrackHost] = @element
    JS.eval(<<~JS)
      (() => {
        const host = window.__wcTrackHost;
        const opts = host.__abort ? { signal: host.__abort.signal } : undefined;
        window.addEventListener("presetsUpdated", () => {
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].refresh_preset_list"); } catch(_) {}
        }, opts);
      })();
    JS
    JS.global.call(:eval, "delete window.__wcTrackHost")
  end

  def style(el, **styles)
    s = el[:style]
    styles.each { |k, v| s[k] = v }
  end

  TrackControls.register("track-controls")
end
