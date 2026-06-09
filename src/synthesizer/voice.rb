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

    build_graph
  end

  def build_graph
    freq = @freq

    # 1. Create Nodes defined in the patch
    @patch[:nodes].each do |n|
      node = nil
      case n[:type]
      when "Oscillator"
        node = OscillatorNode.new(@ctx)
        node.type = n[:params][:type] if n.dig(:params, :type)
        if n[:freq_track]
          node.frequency.value = freq
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
        target = @nodes[target_id]
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

  private
end