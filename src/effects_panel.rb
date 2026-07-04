require 'js'
require 'web_component'

class EffectsPanel
  include WebComponent

  PARAMS = [
    { id: "delay_time",     label: "Time",     min: 0.0, max: 1.0,  step: 0.01, default: 0.3, suffix: " s", panel: :delay },
    { id: "delay_feedback", label: "Feedback", min: 0.0, max: 0.95, step: 0.01, default: 0.4, suffix: "",   panel: :delay },
    { id: "delay_level",    label: "Level",    min: 0.0, max: 1.0,  step: 0.01, default: 0.5, suffix: "",   panel: :delay },
    # reverb_seconds regenerates the convolution IR (a costly 2ch buffer) on
    # every apply, so only apply it on `change` (drag release) rather than on
    # every `input` tick.
    { id: "reverb_seconds", label: "Seconds",  min: 0.1, max: 5.0,  step: 0.1,  default: 2.0, suffix: " s", panel: :reverb, apply_on: :change },
    { id: "reverb_level",   label: "Level",    min: 0.0, max: 1.0,  step: 0.01, default: 0.5, suffix: "",   panel: :reverb }
  ]

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]
    @inputs = {}
    @displays = {}

    @element[:style][:display] = "contents"

    build_panel("Delay Send", :delay)
    build_panel("Reverb Send", :reverb)

    update_from_controller
    install_global_event_listeners
  end

  def update_from_controller
    return unless controller
    PARAMS.each do |p|
      val = controller.send(p[:id]).to_f
      @inputs[p[:id]][:value] = val.to_s
      @displays[p[:id]][:textContent] = "#{format_value(val)}#{p[:suffix]}"
    end
  rescue => e
    puts "[EffectsPanel] update error: #{e.message}"
  end

  private

  # The panel is dedicated to the sequencer's send/return chain.
  def controller
    $sequencer&.effects_chain
  end

  def build_panel(title, panel_key)
    panel = @doc.call(:createElement, "div")
    panel[:className] = "panel"

    h2 = @doc.call(:createElement, "h2")
    h2[:textContent] = title
    panel.call(:appendChild, h2)

    PARAMS.select { |p| p[:panel] == panel_key }.each do |p|
      panel.call(:appendChild, build_slider(p))
    end

    @element.call(:appendChild, panel)
  end

  def build_slider(p)
    grp = @doc.call(:createElement, "div")
    grp[:className] = "control-group"

    label = @doc.call(:createElement, "label")
    label[:textContent] = "#{p[:label]} "
    display = @doc.call(:createElement, "span")
    display[:className] = "value-display"
    display[:textContent] = "#{format_value(p[:default])}#{p[:suffix]}"
    label.call(:appendChild, display)
    grp.call(:appendChild, label)
    @displays[p[:id]] = display

    input = @doc.call(:createElement, "input")
    input[:type] = "range"
    input.call(:setAttribute, "min", p[:min].to_s)
    input.call(:setAttribute, "max", p[:max].to_s)
    input.call(:setAttribute, "step", p[:step].to_s)
    input[:value] = p[:default].to_s
    grp.call(:appendChild, input)
    @inputs[p[:id]] = input

    pid = p[:id]
    suffix = p[:suffix]
    apply_on_change = p[:apply_on] == :change

    apply = proc {
      val = input[:value].to_f
      controller&.send(:"#{pid}=", val)
    }

    # `input` always keeps the display in sync during the drag; params that opt
    # into apply_on: :change defer the (expensive) controller apply to release.
    input.call(:addEventListener, "input", proc {
      val = input[:value].to_f
      display[:textContent] = "#{format_value(val)}#{suffix}"
      apply.call unless apply_on_change
    })
    input.call(:addEventListener, "change", apply) if apply_on_change

    grp
  end

  def format_value(val)
    # Match the original UI: integers when possible, else trimmed float
    if val == val.to_i
      val.to_i.to_s
    else
      ("%.2f" % val).sub(/0+$/, "").sub(/\.$/, "")
    end
  end

  def install_global_event_listeners
    rid = @element[:__rubyId].to_s
    JS.global[:__wcEffectsHost] = @element
    JS.eval(<<~JS)
      (() => {
        const host = window.__wcEffectsHost;
        const opts = host.__abort ? { signal: host.__abort.signal } : undefined;
        window.addEventListener("projectLoaded", () => {
          try { App.eval("WebComponent::WC_REGISTRY[#{rid}].update_from_controller"); } catch(_) {}
        }, opts);
      })();
    JS
    JS.global.call(:eval, "delete window.__wcEffectsHost")
  end

  EffectsPanel.register("effects-panel")
end
