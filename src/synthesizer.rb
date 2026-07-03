require "js"
require "json"
require_relative "synthesizer/nodes"
require_relative "synthesizer/voice"

class Synthesizer
  # Parameters
  attr_accessor :custom_patch
  attr_reader :master_gain

  def initialize(ctx)
    @ctx = ctx

    build_global_graph
    @custom_patch = default_patch

    @active_voices = {}
  end

  def build_global_graph
    # --- Master Output ---
    @master_gain = GainNode.new(@ctx, gain: 0.5)
    @final_node = @master_gain
  end

  def connect(destination)
    @final_node.connect(destination)
  end

  def disconnect(destination = nil)
    if destination
      @final_node.disconnect(destination)
    else
      @final_node.disconnect
    end
  end

  def default_patch
    {
      nodes: [
        { id: "vco", type: "Oscillator", freq_track: true, params: { type: "sawtooth" } },
        { id: "vcf", type: "BiquadFilter", params: { type: "lowpass", frequency: 2000.0, q: 5.0 } },
        { id: "vca", type: "Gain", params: { gain: 0.0 } },
        { id: "env", type: "ADSR", params: { attack: 0.1, decay: 0.2, sustain: 0.5, release: 0.5 } },
        { id: "lfo", type: "Oscillator", params: { type: "sine", frequency: 5.0 } },
        { id: "lfo_gain", type: "Gain", params: { gain: 500.0 } }
      ],
      connections: [
        { from: "vco", to: "vcf" },
        { from: "vcf", to: "vca" },
        { from: "vca", to: "out" },
        { from: "env", to: "vca.gain" },
        { from: "lfo", to: "lfo_gain" },
        { from: "lfo_gain", to: "vcf.frequency" }
      ]
    }
  end

  def close
    @final_node&.disconnect
    @active_voices.values.each(&:stop_immediately)
    @active_voices.clear
  end

  # Noise buffers are read-only and can be shared across every Synthesizer /
  # Voice via multiple AudioBufferSourceNodes. Generate each one lazily and
  # only once per class, so adding tracks (a DrumMachine spins up 4 synths)
  # doesn't regenerate ~3.5MB of buffers each time.
  def self.shared_noise_buffer(ctx)
    @shared_noise_buffer ||= create_noise_buffer(ctx)
  end

  def self.shared_pink_noise_buffer(ctx)
    @shared_pink_noise_buffer ||= create_pink_noise_buffer(ctx)
  end

  def self.create_noise_buffer(ctx)
    rate = ctx[:sampleRate].to_f
    length = rate.to_i # 1 second of noise

    # Using raw JS for buffer creation as before
    JS.eval(<<~JAVASCRIPT)
      const buffer = window._tempNoiseBuffer = window.audioCtx.createBuffer(1, #{length}, window.audioCtx.sampleRate);
      const data = buffer.getChannelData(0);
      for (let i = 0; i < #{length}; i++) {
        data[i] = Math.random() * 2 - 1;
      }
    JAVASCRIPT
    buffer = JS.global[:_tempNoiseBuffer]
    JS.eval("delete window._tempNoiseBuffer")
    buffer
  end

  def self.create_pink_noise_buffer(ctx)
    rate = ctx[:sampleRate].to_f
    length = (rate * 4).to_i # 4 seconds of noise (longer loop to soften the seam)
    rows = 16 # Voss-McCartney generators (pink slope down to ~sampleRate/2^16)

    # Voss-McCartney method (McCartney optimization): exactly one of the `rows`
    # white generators is re-randomized per sample, selected by the trailing-zero
    # count of an incrementing counter. We keep a running sum, then peak-normalize.
    JS.eval(<<~JAVASCRIPT)
      const buffer = window._tempPinkBuffer = window.audioCtx.createBuffer(1, #{length}, window.audioCtx.sampleRate);
      const data = buffer.getChannelData(0);

      const ROWS = #{rows};
      const rowValues = new Float32Array(ROWS);
      let runningSum = 0;
      for (let r = 0; r < ROWS; r++) {
        rowValues[r] = Math.random() * 2 - 1; // zero-mean seed -> negligible DC
        runningSum += rowValues[r];
      }

      let counter = 0;
      let maxAbs = 0;
      for (let i = 0; i < #{length}; i++) {
        counter++;
        // index = number of trailing zero bits in counter, capped at ROWS-1
        let index = 0;
        let c = counter;
        while ((c & 1) === 0 && index < ROWS - 1) {
          c >>= 1;
          index++;
        }
        const next = Math.random() * 2 - 1;
        runningSum += next - rowValues[index];
        rowValues[index] = next;

        data[i] = runningSum;
        const a = Math.abs(runningSum);
        if (a > maxAbs) maxAbs = a;
      }

      // Peak-normalize into [-0.99, 0.99]
      const scale = maxAbs > 0 ? (0.99 / maxAbs) : 1;
      for (let i = 0; i < #{length}; i++) {
        data[i] *= scale;
      }
    JAVASCRIPT
    buffer = JS.global[:_tempPinkBuffer]
    JS.eval("delete window._tempPinkBuffer")
    buffer
  end

  def noise_buffer
    self.class.shared_noise_buffer(@ctx)
  end

  def pink_noise_buffer
    self.class.shared_pink_noise_buffer(@ctx)
  end

  def volume=(val)
    @master_gain.gain.value = val.to_f * 0.5
  end

  def note_on(freq)
    return if @ctx.typeof == "undefined"

    if @ctx[:state] == "suspended"
      @ctx.call(:resume)
    end

    # Stop existing voice for this frequency if any
    if @active_voices[freq]
      @active_voices[freq].stop_immediately
    end

    voice = Voice.new(@ctx, freq, @custom_patch, self)
    @active_voices[freq] = voice
    voice.start(@ctx[:currentTime].to_f)
  end

  def note_off(freq)
    voice = @active_voices[freq]
    if voice
      voice.stop(@ctx[:currentTime].to_f)
      @active_voices.delete(freq)
    end
  end

  def schedule_note(freq, start_time, duration, velocity: 0.8)
    voice = Voice.new(@ctx, freq, @custom_patch, self)
    voice.start(start_time, velocity: velocity)
    voice.stop(start_time + duration)
  end

  # --- Preset Management ---

  def import_patch(json_str)
    @custom_patch = JSON.parse(json_str.to_s, symbolize_names: true)
  end

  def export_patch
    JSON.generate(@custom_patch)
  end
end
