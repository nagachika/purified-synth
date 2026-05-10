require 'js'
require 'web_component'

class TabBar
  include WebComponent

  TABS = [
    { id: "synth",   label: "Synthesizer", view: "synthesizer" },
    { id: "chord",   label: "Chord",       view: "chord" },
    { id: "seq",     label: "Sequencer",   view: "sequencer" },
    { id: "pattern", label: "Pattern",     view: "pattern" }
  ]

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]
    @buttons = {}
    @views = {}

    @element[:className] = "tabs"
    build_dom

    # Apply default active state matching the initial HTML (synth tab)
    # without performing the full context switch — globals like
    # $midiProcessor may not be initialized at this point.
    @buttons["synth"][:classList].call(:add, "active")
  end

  def switch_tab(tab_id)
    @buttons.each_value { |b| b[:classList].call(:remove, "active") }
    @views.each_value { |v| v[:classList].call(:remove, "active") unless v.nil? }

    @buttons[tab_id][:classList].call(:add, "active")
    view = @views[tab_id]
    view[:classList].call(:add, "active") if view

    apply_context(tab_id)

    JS.eval("window.dispatchEvent(new Event('effectControllerChanged'))")

    begin
      $midiProcessor.set_tab(tab_id) if $midiProcessor
    rescue => e
      puts "[TabBar] set_tab error: #{e.message}"
    end
  end

  private

  def build_dom
    TABS.each do |t|
      btn = @doc.call(:createElement, "button")
      btn[:textContent] = t[:label]
      btn[:className] = "tab-btn"
      tid = t[:id]
      btn.call(:addEventListener, "click", proc { switch_tab(tid) })
      @element.call(:appendChild, btn)
      @buttons[t[:id]] = btn

      @views[t[:id]] = @doc.call(:getElementById, "view-#{t[:view]}")
    end

    status = @doc.call(:createElement, "span")
    status[:id] = "midi-status"
    status[:textContent] = "MIDI: --"
    s = status[:style]
    s[:fontSize] = "0.75rem"
    s[:color] = "#aaa"
    s[:marginLeft] = "12px"
    s[:alignSelf] = "center"
    @element.call(:appendChild, status)
  end

  def apply_context(tab_id)
    case tab_id
    when "synth"
      $synth = $previewSynth
      $effect_controller = $previewEffects
      JS.global[:window][:synthAnalyser] = $previewAnalyser.native_node
      refresh_modular_editor
    when "seq"
      $effect_controller = $sequencer.effects_chain
      JS.eval("window.dispatchEvent(new Event('trackChanged'))")
    when "chord"
      $synth = $chordSynth
      $effect_controller = $chordEffects
      refresh_modular_editor
    when "pattern"
      # no-op
    end
  rescue => e
    puts "[TabBar] apply_context(#{tab_id}) error: #{e.message}"
  end

  def refresh_modular_editor
    return unless $synth
    JS.global[:_patchJson] = $synth.export_patch
    JS.eval(<<~JS)
      if (window.modularEditor) {
        try { window.modularEditor.loadPatch(JSON.parse(window._patchJson)); } catch(e) { console.error(e); }
      }
      delete window._patchJson;
    JS
  rescue => e
    puts "[TabBar] refresh_modular_editor error: #{e.message}"
  end

  TabBar.register("tab-bar")
end
