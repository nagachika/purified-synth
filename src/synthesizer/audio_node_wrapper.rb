require "js"

# Wraps a native Web Audio API AudioParam
class AudioParamWrapper
  attr_reader :native_node

  def initialize(native_param)
    @native_node = native_param
  end

  def value=(val)
    @native_node[:value] = val.to_f
  end

  def value
    @native_node[:value].to_f
  end

  # Automations
  def set_value_at_time(value, time)
    @native_node.call(:setValueAtTime, value.to_f, time.to_f)
  end

  def linear_ramp_to_value_at_time(value, time)
    @native_node.call(:linearRampToValueAtTime, value.to_f, time.to_f)
  end

  def exponential_ramp_to_value_at_time(value, time)
    # Exponential ramp requires positive non-zero values
    val = value.to_f
    val = 0.0001 if val.abs < 0.0001
    @native_node.call(:exponentialRampToValueAtTime, val, time.to_f)
  end

  def cancel_scheduled_values(time)
    @native_node.call(:cancelScheduledValues, time.to_f)
  end

  def cancel_and_hold_at_time(time)
    t = time.to_f
    if @native_node[:cancelAndHoldAtTime].typeof == "function"
      begin
        @native_node.call(:cancelAndHoldAtTime, t)
        return
      rescue
        # Firefox may throw; fall through to fallback
      end
    end
    # Fallback: cancel future events and freeze at the current intrinsic value
    @native_node.call(:cancelScheduledValues, t)
    @native_node.call(:setValueAtTime, @native_node[:value].to_f, t)
  end

  def set_target_at_time(target, time, time_constant)
    @native_node.call(:setTargetAtTime, target.to_f, time.to_f, time_constant.to_f)
  end
end

# Base wrapper for Web Audio API AudioNodes
class AudioNodeWrapper
  attr_reader :native_node, :ctx

  def initialize(ctx, native_node)
    @ctx = ctx
    @native_node = native_node
  end

  def connect(destination)
    if destination.is_a?(AudioNodeWrapper) || destination.is_a?(AudioParamWrapper)
      @native_node.connect(destination.native_node)
    elsif destination.is_a?(JS::Object)
      # Fallback for raw JS objects (like ctx.destination)
      @native_node.connect(destination)
    else
      raise ArgumentError, "Cannot connect to #{destination.class}"
    end
    self # Allow chaining
  end

  def disconnect(destination = nil)
    if destination
      if destination.is_a?(AudioNodeWrapper) || destination.is_a?(AudioParamWrapper)
        @native_node.disconnect(destination.native_node)
      elsif destination.is_a?(JS::Object)
        @native_node.disconnect(destination)
      else
        raise ArgumentError, "Cannot disconnect from #{destination.class}"
      end
    else
      @native_node.disconnect
    end
  end

  # Helper to access parameters wrapped in AudioParamWrapper
  # Child classes should define specific parameter accessors
  def param(name)
    raw_param = @native_node[name]
    if raw_param.typeof == "undefined"
      raise ArgumentError, "AudioParam '#{name}' not found on #{@native_node[:constructor][:name]}"
    end
    AudioParamWrapper.new(raw_param)
  end
end
