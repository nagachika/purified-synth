// Thin bridge to the Ruby-side $presets store (source of truth in
// localStorage), used only by project save/load. The Presets UI itself is the
// <presets-panel> WebComponent (src/presets_panel.rb).

export function getPresets() {
  try {
    return JSON.parse(window.App.call("$presets", "get_presets").toString());
  } catch (e) {
    console.error(e);
    return {};
  }
}

export function setPresets(newPresets) {
  window.App.call("$presets", "set_presets", newPresets || {});
  // Refreshes the <presets-panel> list and every preset select (track
  // controls, chord editor preview) after a project load.
  window.dispatchEvent(new Event("presetsUpdated"));
}
