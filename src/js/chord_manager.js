// Thin bridge to the Ruby-side $chordManager store (source of truth in
// localStorage), used only by project save/load. Chord editing UIs live in
// the Ruby WebComponents and talk to $chordManager directly.

export function getChords() {
  try {
    return JSON.parse(window.App.call("$chordManager", "get_chords").toString());
  } catch (e) {
    console.error(e);
    return {};
  }
}

export function setChords(newChords) {
  window.App.call("$chordManager", "set_chords", newChords || {});
  // Refreshes the chord editor's saved-chord list after a project load.
  window.dispatchEvent(new Event("chordsUpdated"));
}
