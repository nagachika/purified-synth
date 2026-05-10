require 'js'

# Mixin that turns a Ruby class into a Web Component (custom element).
#
# Usage:
#   class MyWidget
#     include WebComponent
#
#     def connected_callback(js_element)
#       # build DOM here using JS gem
#     end
#
#     MyWidget.register("my-widget")
#   end
#
# Design note: connectedCallback in the generated JS class calls App.eval()
# to instantiate the Ruby object and delegate lifecycle methods.
# To avoid Ruby VM re-entrancy, the custom element must NOT already be in the
# DOM when register() is called.  Add the element to the DOM from JS *after*
# the require that triggers register() returns.
module WebComponent
  WC_REGISTRY = {}
  WC_NEXT_ID  = [0]  # mutable container so register() can bump without reassigning the constant

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def register(tag_name)
      ruby_class_name = name

      js_code = <<~JS
        (() => {
          class RubyComponent extends HTMLElement {
            connectedCallback() {
              if (this.__rubyId !== undefined) return;

              this.__abort = new AbortController();

              window.__wcElement = this;
              const id = App.eval(`
                inst = #{ruby_class_name}.new
                id   = WebComponent::WC_NEXT_ID[0]
                WebComponent::WC_NEXT_ID[0] = id + 1
                WebComponent::WC_REGISTRY[id] = inst
                this_elem = JS.global[:__wcElement]
                this_elem[:__rubyId] = id
                inst.connected_callback(this_elem)
                id
              `).toJS();
              delete window.__wcElement;
              this.__rubyId = id;
            }

            disconnectedCallback() {
              if (this.__rubyId === undefined) return;
              const id = this.__rubyId;

              if (this.__abort) {
                this.__abort.abort();
                this.__abort = undefined;
              }

              window.__wcElement = this;
              App.eval(`
                id   = JS.global[:__wcElement][:__rubyId].to_i
                inst = WebComponent::WC_REGISTRY.delete(id)
                inst.disconnected_callback if inst
              `);
              delete window.__wcElement;

              this.__rubyId = undefined;
            }
          }

          customElements.define('#{tag_name}', RubyComponent);
        })();
      JS

      JS.eval(js_code)
      puts "[WebComponent] registered <#{tag_name}>"
    end
  end

  def connected_callback(element); end
  def disconnected_callback; end
end
