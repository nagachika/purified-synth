require "json"

# Globals reachable from JS via App.call. Lambdas defer the lookup so the
# bridge sees the current value even when a global is reassigned (e.g. $synth
# is swapped on tab switches).
BRIDGE_TARGETS = {
  '$sequencer'         => -> { $sequencer },
  '$patternSequencer'  => -> { $patternSequencer },
  '$synth'             => -> { $synth },
  '$previewSynth'      => -> { $previewSynth },
  '$chordSynth'        => -> { $chordSynth },
  '$midiProcessor'     => -> { $midiProcessor },
  '$chordManager'      => -> { $chordManager },
  '$presets'           => -> { $presets }
}.freeze

# Facade for JavaScript to Ruby communication.
# Arguments are passed as a JSON string to ensure safe type conversion.
def js_bridge_dispatch(target_name, method_name, json_args)
  target = if target_name.start_with?('wc:')
             WebComponent::WC_REGISTRY[target_name[3..].to_i]
           else
             resolver = BRIDGE_TARGETS[target_name]
             unless resolver
               puts "[Bridge Error] Unknown target: #{target_name}"
               return nil
             end
             resolver.call
           end

  if target.nil?
    puts "[Bridge Error] Target #{target_name} is nil. Initialization might have failed."
    return nil
  end

  unless target.respond_to?(method_name)
    puts "[Bridge Error] #{target_name} does not respond to #{method_name}"
    return nil
  end

  begin
    args = JSON.parse(json_args)
    # Method call with splatted arguments
    target.send(method_name, *args)
  rescue => e
    puts "[Bridge Exception] #{e.message}"
    puts e.backtrace
    nil
  end
end
