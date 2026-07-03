require 'js'
require 'json'
require 'web_component'

# Presets (Sound Design) panel on the Synthesizer view. Saves/loads/deletes
# named patches of the currently active $synth via the $presets store.
class PresetsPanel
  include WebComponent

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]

    # Participate directly in the view-synthesizer grid, like <effects-panel>.
    @element[:style][:display] = "contents"

    build_dom
    update_list
    install_global_event_listeners
  end

  def update_list
    @list_sel[:innerHTML] = ""
    placeholder = @doc.call(:createElement, "option")
    placeholder[:value] = ""
    placeholder[:textContent] = "-- Select Preset --"
    @list_sel.call(:appendChild, placeholder)

    $presets.presets.keys.each do |name|
      opt = @doc.call(:createElement, "option")
      opt[:value] = name
      opt[:textContent] = name
      @list_sel.call(:appendChild, opt)
    end
  rescue => e
    puts "[PresetsPanel] update_list error: #{e.message}"
  end

  private

  def build_dom
    panel = @doc.call(:createElement, "div")
    panel[:className] = "panel"
    panel[:style][:gridColumn] = "1 / -1"

    h2 = @doc.call(:createElement, "h2")
    h2[:textContent] = "Presets (Sound Design)"
    panel.call(:appendChild, h2)

    row = @doc.call(:createElement, "div")
    style(row, display: "flex", gap: "10px", flexWrap: "wrap", alignItems: "center")

    @name_input = @doc.call(:createElement, "input")
    @name_input[:type] = "text"
    @name_input[:id] = "preset_name"
    @name_input.call(:setAttribute, "placeholder", "Preset Name")
    style(@name_input,
      padding: "8px", borderRadius: "4px", border: "1px solid #555",
      background: "#222", color: "#fff", flexGrow: "1"
    )
    # Keep typing in the name field from triggering synth keyboard shortcuts.
    @name_input.call(:addEventListener, "keydown", proc { |e| e.call(:stopPropagation) })
    row.call(:appendChild, @name_input)

    @save_btn = build_button("Save", "#28a745")
    @save_btn[:id] = "save_preset"
    @save_btn.call(:addEventListener, "click", proc { on_save })
    row.call(:appendChild, @save_btn)

    @list_sel = @doc.call(:createElement, "select")
    @list_sel[:id] = "preset_list"
    style(@list_sel,
      padding: "8px", borderRadius: "4px", border: "1px solid #555",
      background: "#222", color: "#fff", flexGrow: "1", maxWidth: "200px"
    )
    row.call(:appendChild, @list_sel)

    @load_btn = build_button("Load", "#17a2b8")
    @load_btn[:id] = "load_preset"
    @load_btn.call(:addEventListener, "click", proc { on_load })
    row.call(:appendChild, @load_btn)

    @delete_btn = build_button("Delete", "#dc3545")
    @delete_btn[:id] = "delete_preset"
    @delete_btn.call(:addEventListener, "click", proc { on_delete })
    row.call(:appendChild, @delete_btn)

    panel.call(:appendChild, row)
    @element.call(:appendChild, panel)
  end

  def build_button(label, background)
    btn = @doc.call(:createElement, "button")
    btn[:textContent] = label
    style(btn, padding: "8px 15px", background: background)
    btn
  end

  def on_save
    name = @name_input[:value].to_s.strip
    if name.empty?
      JS.global.call(:alert, "Please enter a preset name.")
      return
    end
    $presets.update_preset(name, $synth.export_patch)
    notify_presets_updated
    JS.global.call(:alert, "Preset \"#{name}\" saved!")
    @name_input[:value] = ""
    update_list
  rescue => e
    puts "[PresetsPanel] save error: #{e.message}"
  end

  def on_load
    name = @list_sel[:value].to_s
    return if name.empty?
    json = $presets.presets[name]
    return unless json

    data = JSON.parse(json)
    unless data["nodes"]
      puts "[PresetsPanel] legacy preset format is no longer supported"
      return
    end

    $synth.import_patch(json)
    refresh_modular_editor(json)
  rescue => e
    puts "[PresetsPanel] load error: #{e.message}"
  end

  def on_delete
    name = @list_sel[:value].to_s
    return if name.empty?
    confirmed = JS.global.call(:confirm, "Delete preset \"#{name}\"?").to_s == "true"
    return unless confirmed
    $presets.delete_preset(name)
    notify_presets_updated
    update_list
  rescue => e
    puts "[PresetsPanel] delete error: #{e.message}"
  end

  # Same pattern as TabBar#refresh_modular_editor: hand the patch JSON to the
  # D3 editor (which stays JS-side) through a temporary global.
  def refresh_modular_editor(json)
    JS.global[:_patchJson] = json
    JS.eval(<<~JS)
      if (window.modularEditor) {
        try { window.modularEditor.loadPatch(JSON.parse(window._patchJson)); } catch(e) { console.error(e); }
      }
      delete window._patchJson;
    JS
  end

  def notify_presets_updated
    JS.eval("setTimeout(() => window.dispatchEvent(new Event('presetsUpdated')), 0)")
  end

  def install_global_event_listeners
    rid = @element[:__rubyId].to_i
    JS.global[:__wcSignal] = @element[:__abort][:signal]
    JS.eval(<<~JS)
      (() => {
        const signal = window.__wcSignal;
        delete window.__wcSignal;
        window.addEventListener("presetsUpdated", () => {
          try { App.call("wc:#{rid}", "update_list"); } catch(e) {}
        }, { signal });
      })();
    JS
  end

  def style(el, **styles)
    s = el[:style]
    styles.each { |k, v| s[k] = v }
  end

  PresetsPanel.register("presets-panel")
end
