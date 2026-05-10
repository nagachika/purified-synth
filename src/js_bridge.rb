require "json"

# Facade for JavaScript to Ruby communication.
# Arguments are passed as a JSON string to ensure safe type conversion.
def js_bridge_dispatch(target_name, method_name, json_args)
  target = if target_name.start_with?('wc:')
             WebComponent::WC_REGISTRY[target_name[3..].to_i]
           else
             case target_name
             when '$sequencer'        then $sequencer
             when '$patternSequencer' then $patternSequencer
             when '$synth'            then $synth
             when '$previewSynth'     then $previewSynth
             when '$chordSynth'       then $chordSynth
             when '$effect_controller' then $effect_controller
             when '$midiProcessor'    then $midiProcessor
             when '$chordManager'     then $chordManager
             when '$presets'          then $presets
             else
               puts "[Bridge Error] Unknown target: #{target_name}"
               return nil
             end
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
