require 'js'
require 'json'
require 'web_component'
require 'lattice_view'

# Single timeline block on the sequencer view. The host element itself is the
# block div; sequencer_ui.js absolute-positions it within the track grid based
# on attributes and calls refresh() when length/type/notes change.
class SequencerBlock
  include WebComponent
  include LatticeView

  CELL_WIDTH = 10

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]

    @track_idx = element.call(:getAttribute, "track-index").to_i
    @start_step = element.call(:getAttribute, "start-step").to_i
    @length = element.call(:getAttribute, "length").to_i
    @track_type = element.call(:getAttribute, "track-type").to_s

    @element[:className] = "block"
    style_host
    render_content
    bind_events
  end

  # Called from sequencer_ui.js when block content/length/type changes.
  def refresh(length, track_type)
    @length = length.to_i
    @track_type = track_type.to_s
    @element[:style][:left] = "#{@start_step * CELL_WIDTH}px"
    @element[:style][:width] = "#{@length * CELL_WIDTH}px"
    @element[:innerHTML] = ""
    render_content
  end

  private

  def style_host
    s = @element[:style]
    s[:position] = "absolute"
    s[:left] = "#{@start_step * CELL_WIDTH}px"
    s[:width] = "#{@length * CELL_WIDTH}px"
    s[:height] = "100%"
    s[:border] = "1px solid #fff"
    s[:borderRadius] = "4px"
    s[:cursor] = "pointer"
    s[:zIndex] = "5"
    s[:display] = "flex"
    s[:alignItems] = "center"
    s[:justifyContent] = "center"
    s[:overflow] = "hidden"
  end

  def render_content
    if @track_type == "rhythmic"
      render_rhythmic
    else
      render_melodic
    end
  rescue => e
    puts "[SequencerBlock] render error: #{e.message}"
  end

  def render_rhythmic
    @element[:style][:background] = "#ff8787"
    pid = $sequencer.get_block_pattern_id(@track_idx, @start_step).to_s
    pname = $sequencer.get_pattern_name(pid).to_s
    @element[:textContent] = pname
    s = @element[:style]
    s[:color] = "black"
    s[:fontSize] = "0.8rem"
    s[:fontWeight] = "bold"
  end

  def render_melodic
    notes = JSON.parse($sequencer.get_block_notes_json(@track_idx, @start_step).to_s)
    @element[:style][:background] = notes.length > 0 ? "#4dabf7" : "#555"
    @element[:title] = "Start: #{@start_step}"

    canvas = @doc.call(:createElement, "canvas")
    cw = @length * CELL_WIDTH - 4
    ch = 70
    canvas[:width] = cw > 0 ? cw : 1
    canvas[:height] = ch
    canvas[:style][:display] = "block"
    draw_tetris_shape(canvas.call(:getContext, "2d"), notes, cw, ch, nil)
    @element.call(:appendChild, canvas)
  end

  def bind_events
    @element.call(:addEventListener, "click", proc { |e|
      e.call(:stopPropagation)
      on_click
    })
    @element.call(:addEventListener, "contextmenu", proc { |e|
      e.call(:preventDefault)
      on_context_menu
    })
  end

  def on_click
    if @track_type == "rhythmic"
      pid = $sequencer.get_block_pattern_id(@track_idx, @start_step).to_s
      $pattern_selector_modal&.open(@track_idx, @start_step, pid)
    else
      $chord_selector_modal&.open(@track_idx, @start_step)
    end
  end

  def on_context_menu
    confirmed = JS.global.call(:confirm, "Delete block?").to_s == "true"
    return unless confirmed
    $sequencer.remove_block(@track_idx, @start_step)
    JS.eval("setTimeout(() => window.dispatchEvent(new Event('seqBlockUpdated')), 0)")
  end

  SequencerBlock.register("sequencer-block")
end
