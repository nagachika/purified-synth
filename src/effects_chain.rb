require "js"
require_relative "synthesizer/nodes"

# Send/return effects for the Sequencer. The chain is wet-only: tracks keep
# their dry path straight to the sequencer master, so the return must not
# re-add the dry signal (that would double it). Delay and reverb run in
# parallel from the send bus, each with its own return level.
class EffectsChain
  DEFAULTS = {
    delay_time: 0.3,
    delay_feedback: 0.4,
    delay_level: 0.5,
    reverb_seconds: 2.0,
    reverb_level: 0.5
  }.freeze

  attr_reader :input_node, :output_node
  attr_reader :delay_time, :delay_feedback, :delay_level
  attr_reader :reverb_seconds, :reverb_level

  def initialize(ctx)
    @ctx = ctx

    DEFAULTS.each { |name, value| instance_variable_set("@#{name}", value) }

    build_graph
  end

  def build_graph
    @input_node = GainNode.new(@ctx)
    @output_node = GainNode.new(@ctx)

    # --- Delay (parallel, wet only) ---
    @delay_node = DelayNode.new(@ctx, delay_time: @delay_time)
    @delay_feedback_gain = GainNode.new(@ctx, gain: @delay_feedback)
    @delay_return_gain = GainNode.new(@ctx, gain: @delay_level)

    @input_node.connect(@delay_node)
    @delay_node.connect(@delay_feedback_gain)
    @delay_feedback_gain.connect(@delay_node)
    @delay_node.connect(@delay_return_gain)
    @delay_return_gain.connect(@output_node)

    # --- Reverb (parallel, wet only) ---
    @convolver = ConvolverNode.new(@ctx)
    @reverb_return_gain = GainNode.new(@ctx, gain: @reverb_level)

    @input_node.connect(@convolver)
    @convolver.connect(@reverb_return_gain)
    @reverb_return_gain.connect(@output_node)

    update_reverb_buffer
  end

  def connect(destination)
    @output_node.connect(destination)
  end

  def disconnect(destination = nil)
    if destination
      @output_node.disconnect(destination)
    else
      @output_node.disconnect
    end
  end

  # Parameter Setters

  def delay_time=(val)
    @delay_time = val.to_f
    @delay_node.delay_time.value = @delay_time if @delay_node
  end

  def delay_feedback=(val)
    @delay_feedback = val.to_f
    @delay_feedback_gain.gain.value = @delay_feedback if @delay_feedback_gain
  end

  def delay_level=(val)
    @delay_level = val.to_f
    @delay_return_gain.gain.value = @delay_level if @delay_return_gain
  end

  def reverb_seconds=(val)
    @reverb_seconds = val.to_f
    update_reverb_buffer
  end

  def reverb_level=(val)
    @reverb_level = val.to_f
    @reverb_return_gain.gain.value = @reverb_level if @reverb_return_gain
  end

  def reset_to_defaults
    DEFAULTS.each { |name, value| public_send("#{name}=", value) }
  end

  def update_reverb_buffer
    @convolver.buffer = ReverbEffectNode.ir_buffer(@ctx, @reverb_seconds)
  end
end
