require_relative "audio_node_wrapper"

class OscillatorNode < AudioNodeWrapper
  def initialize(ctx, type: "sine", frequency: 440.0)
    native = ctx.call(:createOscillator)
    super(ctx, native)
    self.type = type
    self.frequency.value = frequency
  end

  def type=(val)
    @native_node[:type] = val.to_s
  end

  def frequency
    @frequency ||= param(:frequency)
  end

  def detune
    @detune ||= param(:detune)
  end

  def start(time = 0)
    @native_node.call(:start, time.to_f)
  end

  def stop(time = 0)
    @native_node.call(:stop, time.to_f)
  end
end

class GainNode < AudioNodeWrapper
  def initialize(ctx, gain: 1.0)
    native = ctx.call(:createGain)
    super(ctx, native)
    self.gain.value = gain
  end

  def gain
    @gain ||= param(:gain)
  end
end

class BiquadFilterNode < AudioNodeWrapper
  def initialize(ctx, type: "lowpass", frequency: 350.0, q: 1.0)
    native = ctx.call(:createBiquadFilter)
    super(ctx, native)
    self.type = type
    self.frequency.value = frequency
    self.Q.value = q
  end

  def type=(val)
    @native_node[:type] = val.to_s
  end

  def frequency
    @frequency ||= param(:frequency)
  end

  def detune
    @detune ||= param(:detune)
  end

  def Q
    @Q ||= param(:Q)
  end

  def gain
    # Only used for peaking/shelf filters
    @gain ||= param(:gain)
  end
end

class DelayNode < AudioNodeWrapper
  def initialize(ctx, delay_time: 0.0)
    native = ctx.call(:createDelay, 5.0) # Max delay time 5s
    super(ctx, native)
    self.delay_time.value = delay_time
  end

  def delay_time
    @delay_time ||= param(:delayTime)
  end
end

class ConvolverNode < AudioNodeWrapper
  def initialize(ctx)
    native = ctx.call(:createConvolver)
    super(ctx, native)
  end

  def buffer=(buffer)
    @native_node[:buffer] = buffer
  end

  def normalize=(val)
    @native_node[:normalize] = val
  end
end

class DynamicsCompressorNode < AudioNodeWrapper
  def initialize(ctx)
    native = ctx.call(:createDynamicsCompressor)
    super(ctx, native)
  end

  def threshold
    @threshold ||= param(:threshold)
  end

  def knee
    @knee ||= param(:knee)
  end

  def ratio
    @ratio ||= param(:ratio)
  end

  def attack
    @attack ||= param(:attack)
  end

  def release
    @release ||= param(:release)
  end
end

class CombFilterNode < AudioNodeWrapper
  def initialize(ctx, frequency: 440.0, q: 0.0)
    @input_gain = ctx.call(:createGain)
    @output_gain = ctx.call(:createGain)
    @delay = ctx.call(:createDelay, 1.0) # Max delay 1s
    @feedback = ctx.call(:createGain)

    super(ctx, @input_gain)

    # Topology:
    # Input -> Output (Dry)
    # Input -> Delay -> Output (Wet)
    # Delay -> Feedback -> Delay (Feedback Loop)

    @input_gain.connect(@output_gain)
    @input_gain.connect(@delay)
    @delay.connect(@output_gain)
    @delay.connect(@feedback)
    @feedback.connect(@delay)

    self.set_frequency(frequency)
    self.set_q(q)
  end

  def connect(destination, output_index = 0, input_index = 0)
    dest_node = destination.is_a?(AudioNodeWrapper) ? destination.native_node : destination
    @output_gain.call(:connect, dest_node, output_index, input_index)
    self
  end

  def set_frequency(hz)
    h = hz.to_f
    h = 20.0 if h < 20.0
    # f = 1/T => T = 1/f
    @delay[:delayTime][:value] = 1.0 / h
  end

  def set_q(val)
    # Map Q (0..10+) to Feedback (0..0.95)
    f = val.to_f * 0.1
    f = 0.95 if f > 0.95
    f = 0.0 if f < 0.0
    @feedback[:gain][:value] = f
  end

  def param(name)
    case name.to_s
    when "frequency"
      # Note: This returns the raw delayTime AudioParam (in seconds), not frequency in Hz.
      # Modulation sources connected here will control delay time directly.
      # set_frequency() handles the Hz-to-seconds conversion for static values.
      AudioParamWrapper.new(@delay[:delayTime])
    when "q", "Q", "resonance"
      AudioParamWrapper.new(@feedback[:gain])
    else
      super(name)
    end
  end
end

# Base for composite effect nodes: input flows into @native_node (the input
# gain) while the audible result leaves from @output_gain, so connect and
# disconnect must operate on the output side.
# These node types are instantiated once per Synthesizer and shared by all
# voices (see Synthesizer::SHARED_EFFECT_TYPES), which keeps delay/reverb
# tails ringing after each voice is torn down.
class EffectNodeBase < AudioNodeWrapper
  def connect(destination)
    if destination.is_a?(AudioNodeWrapper) || destination.is_a?(AudioParamWrapper)
      @output_gain.connect(destination.native_node)
    elsif destination.is_a?(JS::Object)
      @output_gain.connect(destination)
    else
      raise ArgumentError, "Cannot connect to #{destination.class}"
    end
    self
  end

  def disconnect(destination = nil)
    if destination
      if destination.is_a?(AudioNodeWrapper) || destination.is_a?(AudioParamWrapper)
        @output_gain.disconnect(destination.native_node)
      elsif destination.is_a?(JS::Object)
        @output_gain.disconnect(destination)
      else
        raise ArgumentError, "Cannot disconnect from #{destination.class}"
      end
    else
      @output_gain.disconnect
    end
  end
end

class DelayEffectNode < EffectNodeBase
  def initialize(ctx, delay_time: 0.3, feedback: 0.4, mix: 0.3)
    @input_gain = ctx.call(:createGain)
    @output_gain = ctx.call(:createGain)
    @delay = ctx.call(:createDelay, 5.0) # Max delay 5s
    @feedback_gain = ctx.call(:createGain)
    @wet_gain = ctx.call(:createGain)
    @dry_gain = ctx.call(:createGain)

    super(ctx, @input_gain)

    # Topology:
    # Input -> Dry -> Output
    # Input -> Delay -> Wet -> Output
    # Delay -> Feedback -> Delay (Feedback Loop)

    @input_gain.connect(@dry_gain)
    @dry_gain.connect(@output_gain)
    @input_gain.connect(@delay)
    @delay.connect(@wet_gain)
    @wet_gain.connect(@output_gain)
    @delay.connect(@feedback_gain)
    @feedback_gain.connect(@delay)

    self.delay_time = delay_time
    self.feedback = feedback
    self.mix = mix
  end

  def delay_time=(val)
    @delay[:delayTime][:value] = val.to_f.clamp(0.0, 5.0)
  end

  def feedback=(val)
    @feedback_gain[:gain][:value] = val.to_f.clamp(0.0, 0.95)
  end

  def mix=(val)
    m = val.to_f.clamp(0.0, 1.0)
    @wet_gain[:gain][:value] = m
    @dry_gain[:gain][:value] = 1.0 - m
  end

  def param(name)
    case name.to_s
    when "delay_time"
      AudioParamWrapper.new(@delay[:delayTime])
    when "feedback"
      AudioParamWrapper.new(@feedback_gain[:gain])
    when "mix"
      # Modulates the wet gain only; the dry gain keeps its static 1-mix value.
      AudioParamWrapper.new(@wet_gain[:gain])
    else
      super(name)
    end
  end
end

class ReverbEffectNode < EffectNodeBase
  def initialize(ctx, seconds: 2.0, mix: 0.3)
    @input_gain = ctx.call(:createGain)
    @output_gain = ctx.call(:createGain)
    @convolver = ctx.call(:createConvolver)
    @wet_gain = ctx.call(:createGain)
    @dry_gain = ctx.call(:createGain)

    super(ctx, @input_gain)

    # Topology:
    # Input -> Dry -> Output
    # Input -> Convolver -> Wet -> Output

    @input_gain.connect(@dry_gain)
    @dry_gain.connect(@output_gain)
    @input_gain.connect(@convolver)
    @convolver.connect(@wet_gain)
    @wet_gain.connect(@output_gain)

    self.seconds = seconds
    self.mix = mix
  end

  def seconds=(val)
    @seconds = val.to_f.clamp(0.1, 5.0)
    @convolver[:buffer] = self.class.ir_buffer(@ctx, @seconds)
  end

  def mix=(val)
    m = val.to_f.clamp(0.0, 1.0)
    @wet_gain[:gain][:value] = m
    @dry_gain[:gain][:value] = 1.0 - m
  end

  def param(name)
    case name.to_s
    when "mix"
      AudioParamWrapper.new(@wet_gain[:gain])
    else
      super(name)
    end
  end

  # Impulse responses are pure functions of the decay length (at a fixed
  # sample rate), so cache them class-wide like Synthesizer.shared_noise_buffer:
  # every ReverbEffectNode and the sequencer send chain share one AudioBuffer
  # per distinct length instead of regenerating seconds of noise on each edit.
  def self.ir_buffer(ctx, seconds)
    @ir_buffers ||= {}
    key = (seconds.to_f * 10).round
    @ir_buffers[key] ||= create_ir_buffer(ctx, seconds.to_f)
  end

  def self.create_ir_buffer(ctx, seconds)
    rate = ctx[:sampleRate].to_f
    length = [(rate * seconds).to_i, 1].max

    JS.eval(<<~JAVASCRIPT)
      const length = #{length};
      const decay = 2.0;
      const buffer = window._tempReverbBuffer = window.audioCtx.createBuffer(2, length, window.audioCtx.sampleRate);
      for (let c = 0; c < 2; c++) {
        const channelData = buffer.getChannelData(c);
        for (let i = 0; i < length; i++) {
          channelData[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / length, decay);
        }
      }
    JAVASCRIPT
    buffer = JS.global[:_tempReverbBuffer]
    JS.eval("delete window._tempReverbBuffer")
    buffer
  end
end

class NoiseNode < AudioNodeWrapper
  def initialize(ctx, buffer)
    native = ctx.call(:createBufferSource)
    super(ctx, native)
    @native_node[:buffer] = buffer
    @native_node[:loop] = true
  end

  def start(time = 0)
    @native_node.call(:start, time.to_f)
  end

  def stop(time = 0)
    @native_node.call(:stop, time.to_f)
  end
end

class ConstantSourceNode < AudioNodeWrapper
  def initialize(ctx, offset: 1.0)
    native = ctx.call(:createConstantSource)
    super(ctx, native)
    self.offset.value = offset
  end

  def offset
    @offset ||= param(:offset)
  end

  def start(time = 0)
    @native_node.call(:start, time.to_f)
  end

  def stop(time = 0)
    @native_node.call(:stop, time.to_f)
  end
end

class AnalyserNode < AudioNodeWrapper
  def initialize(ctx)
    native = ctx.call(:createAnalyser)
    super(ctx, native)
  end

  def fft_size=(size)
    @native_node[:fftSize] = size
  end
end
