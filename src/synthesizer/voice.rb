require "synthesizer/nodes"
require "synthesizer/adsr_envelope"

class Voice
  attr_reader :nodes, :envelopes

  def initialize(ctx, freq, patch, synth)
    @ctx = ctx
    @freq = freq
    @patch = patch
    @synth = synth # Reference to Synthesizer for shared assets like noise_buffer
    @output_node = synth.master_gain # Standard output destination

    @nodes = {}
    @envelopes = {}
    # AudioParams that follow the played note's pitch (freq_track oscillators
    # and Frequency constants); retune() rewrites these when a pooled voice
    # is reused for another note.
    @pitch_params = []

    build_graph
  end

  def build_graph
    freq = @freq

    # 1. Create Nodes defined in the patch
    @patch[:nodes].each do |n|
      # Shared effect nodes live on the Synthesizer, not the voice
      next if Synthesizer::SHARED_EFFECT_TYPES.include?(n[:type])

      node = nil
      case n[:type]
      when "Oscillator"
        node = OscillatorNode.new(@ctx)
        node.type = n[:params][:type] if n.dig(:params, :type)
        if n[:freq_track]
          node.frequency.value = freq
          @pitch_params << node.frequency
        elsif n.dig(:params, :frequency)
          node.frequency.value = n[:params][:frequency]
        end
        @nodes[n[:id]] = node
      when "Noise"
        buffer = n.dig(:params, :type).to_s == "pink" ? @synth.pink_noise_buffer : @synth.noise_buffer
        node = NoiseNode.new(@ctx, buffer)
        @nodes[n[:id]] = node
      when "BiquadFilter"
        node = BiquadFilterNode.new(@ctx)
        node.type = n[:params][:type] if n.dig(:params, :type)
        node.frequency.value = n[:params][:frequency] if n.dig(:params, :frequency)
        node.Q.value = n[:params][:q] if n.dig(:params, :q)
        @nodes[n[:id]] = node
      when "CombFilter"
        node = CombFilterNode.new(@ctx)
        node.set_frequency(n[:params][:frequency]) if n.dig(:params, :frequency)
        node.set_q(n[:params][:q]) if n.dig(:params, :q)
        @nodes[n[:id]] = node
      when "Gain"
        node = GainNode.new(@ctx)
        node.gain.value = n[:params][:gain] if n.dig(:params, :gain)
        @nodes[n[:id]] = node
      when "Constant"
        node = ConstantSourceNode.new(@ctx)
        node.offset.value = n[:params][:offset] if n.dig(:params, :offset)
        @nodes[n[:id]] = node
      when "Frequency"
        # Outputs the played note's frequency (Hz) as a DC signal, e.g. to drive
        # a BiquadFilter's frequency param without going through an Oscillator.
        node = ConstantSourceNode.new(@ctx)
        node.offset.value = freq
        @pitch_params << node.offset
        @nodes[n[:id]] = node
      when "ADSR"
        env = ADSREnvelope.new(
          attack: n[:params][:attack] || 0.1,
          decay: n[:params][:decay] || 0.1,
          sustain: n[:params][:sustain] || 0.5,
          release: n[:params][:release] || 0.5
        )
        @envelopes[n[:id]] = env
      end
    end

    # 2. Establish Connections
    @patch[:connections].each do |conn|
      # Connections originating from shared effect nodes are wired once at
      # the Synthesizer level (see Synthesizer#rebuild_shared_effects).
      next if @synth.shared_effect_nodes.key?(conn[:from])

      source = @nodes[conn[:from]] || @envelopes[conn[:from]]
      unless source
        puts "Warning: Connection source '#{conn[:from]}' not found"
        next
      end

      target_path = conn[:to]
      if target_path == "out"
        source.connect(@output_node)
      else
        target_id, param_name = target_path.split('.')
        target = @nodes[target_id] || @synth.shared_effect_nodes[target_id]
        unless target
          puts "Warning: Connection target '#{target_id}' not found"
          next
        end

        if param_name
          source.connect(target.param(param_name))
        else
          source.connect(target)
        end
      end
    end
  end

  def start(time, velocity: 0.8)
    t = time.to_f
    # Start all source nodes (Oscillators, Noise, Constants)
    @nodes.values.each { |n| n.start(t) if n.respond_to?(:start) }
    # Trigger all envelopes
    @envelopes.values.each { |e| e.trigger(t, velocity) }
  end

  def stop(time)
    t = time.to_f
    # Release all envelopes
    @envelopes.values.each { |e| e.release_at(t) }

    # Find the longest release time to schedule node stopping
    max_release = @envelopes.values.map(&:release).max || 0.1

    # Wait for exponential decay to settle (approx 5 time constants)
    # With setTargetAtTime(target, start, timeConstant=release/3),
    # at t = start + release, value is ~5%.
    # at t = start + release*2, value is ~0.25%.
    # Adding extra buffer to ensure silence.
    stop_time = t + max_release * 2.0 + 1.0

    @nodes.values.each { |n| n.stop(stop_time) if n.respond_to?(:stop) }
  end

  def stop_immediately
    now = @ctx[:currentTime].to_f
    @nodes.values.each { |n| n.stop(now) if n.respond_to?(:stop) }
    @nodes.values.each do |n|
      begin
        n.disconnect
      rescue => e
        puts "Warning: disconnect failed: #{e.message}"
      end
    end
  end

  # --- Pooled-voice lifecycle (see VoicePool) ---
  # Web Audio source nodes are one-shot: once stopped they can never restart.
  # A pooled voice therefore starts its sources exactly once and is gated
  # solely by the envelope-driven VCA; note on/off only touch envelopes and
  # pitch params, and the sources are stopped only on dispose.

  # Start source nodes without triggering envelopes (pool warm-up).
  def start_sources(time)
    t = time.to_f
    @nodes.values.each { |n| n.start(t) if n.respond_to?(:start) }
  end

  # Force every envelope-gated param to 0 so an idle pooled voice is silent
  # regardless of the patch's initial gain values.
  def quiesce
    @envelopes.values.each(&:quiesce)
  end

  def retune(freq, time)
    t = time.to_f
    @pitch_params.each { |p| p.set_value_at_time(freq, t) }
  end

  def trigger_at(time, velocity)
    @envelopes.values.each { |e| e.trigger(time.to_f, velocity) }
  end

  def release_at(time)
    @envelopes.values.each { |e| e.release_at(time.to_f) }
  end

  def max_release
    @envelopes.values.map(&:release).max || 0.1
  end

  # How long a note of `duration` actually sounds before its release phase:
  # a zero-sustain envelope goes silent once attack+decay completes, so the
  # pool can hand the voice out again well before the nominal note end.
  def audible_hold(duration)
    holds = @envelopes.values.map do |e|
      e.sustain.to_f <= 0.001 ? [duration, e.attack.to_f + e.decay.to_f].min : duration
    end
    holds.max || duration
  end

  # Permanently tear the voice down (pool invalidation / synth close).
  def dispose
    stop_immediately
  end

  private
end