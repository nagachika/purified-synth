require 'js'
require 'json'
require 'web_component'

class PatternSelectorModal
  include WebComponent

  def connected_callback(element)
    @element = element
    @doc = JS.global[:document]

    @track_idx = -1
    @start_step = -1
    @current_pattern_id = nil

    style_host_hidden
    build_dom
  end

  def open(track_idx, start_step, current_pattern_id)
    @track_idx = track_idx.to_i
    @start_step = start_step.to_i
    @current_pattern_id = current_pattern_id.to_s
    render_list
    show
  end

  def close
    hide
  end

  private

  def build_dom
    panel = @doc.call(:createElement, "div")
    panel[:className] = "panel"
    style(panel,
      width: "300px", maxWidth: "90%", height: "60%",
      display: "flex", flexDirection: "column"
    )

    header = @doc.call(:createElement, "div")
    style(header,
      display: "flex", justifyContent: "space-between", alignItems: "center",
      marginBottom: "15px", borderBottom: "1px solid #555", paddingBottom: "10px"
    )
    h2 = @doc.call(:createElement, "h2")
    h2[:textContent] = "Select Pattern"
    style(h2, margin: "0", border: "none", padding: "0")
    header.call(:appendChild, h2)

    close_btn = @doc.call(:createElement, "button")
    close_btn[:textContent] = "Close"
    style(close_btn, padding: "5px 10px", background: "#dc3545")
    close_btn.call(:addEventListener, "click", proc { close })
    header.call(:appendChild, close_btn)
    panel.call(:appendChild, header)

    @list_el = @doc.call(:createElement, "div")
    style(@list_el,
      flexGrow: "1", overflowY: "auto", display: "flex",
      flexDirection: "column", gap: "5px"
    )
    panel.call(:appendChild, @list_el)

    @element.call(:appendChild, panel)
  end

  def style_host_hidden
    s = @element[:style]
    s[:display] = "none"
    s[:position] = "fixed"
    s[:top] = "0"
    s[:left] = "0"
    s[:width] = "100%"
    s[:height] = "100%"
    s[:background] = "rgba(0,0,0,0.8)"
    s[:zIndex] = "3000"
    s[:alignItems] = "center"
    s[:justifyContent] = "center"
  end

  def show
    @element[:style][:display] = "flex"
  end

  def hide
    @element[:style][:display] = "none"
  end

  def render_list
    @list_el[:innerHTML] = ""
    patterns = JSON.parse($sequencer.get_patterns_json)

    patterns.each do |p|
      item = @doc.call(:createElement, "div")
      style(item,
        background: (p["id"].to_s == @current_pattern_id) ? "#007bff" : "#444",
        padding: "10px", borderRadius: "4px", cursor: "pointer",
        marginBottom: "5px", color: "white"
      )
      item[:textContent] = p["name"]

      pid = p["id"]
      item.call(:addEventListener, "click", proc {
        $sequencer.set_block_pattern_id(@track_idx, @start_step, pid)
        hide
        # Defer to avoid re-entering Ruby VM from synchronous listeners.
        JS.global[:_pickedPatternId] = pid.to_s
        JS.eval(<<~JS)
          setTimeout(() => {
            window.dispatchEvent(new Event('seqBlockUpdated'));
            window.dispatchEvent(new CustomEvent('selectPattern', { detail: { id: window._pickedPatternId } }));
            delete window._pickedPatternId;
          }, 0);
        JS
      })

      edit_btn = @doc.call(:createElement, "button")
      edit_btn[:textContent] = "Edit"
      style(edit_btn, float: "right", fontSize: "0.7rem")
      edit_btn.call(:addEventListener, "click", proc { |e|
        e.call(:stopPropagation)
        hide
        JS.global[:_pickedPatternId] = pid.to_s
        JS.eval(<<~JS)
          setTimeout(() => {
            const tabPattern = document.getElementById('tab-pattern');
            if (tabPattern) tabPattern.click();
            window.dispatchEvent(new CustomEvent('selectPattern', { detail: { id: window._pickedPatternId } }));
            delete window._pickedPatternId;
          }, 0);
        JS
      })
      item.call(:appendChild, edit_btn)

      @list_el.call(:appendChild, item)
    end
  end

  def style(el, **styles)
    s = el[:style]
    styles.each { |k, v| s[k] = v }
  end

  PatternSelectorModal.register("pattern-selector-modal")
end
