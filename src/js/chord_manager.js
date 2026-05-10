// Thin wrappers around Ruby-side $chordManager (source of truth in localStorage).
// Cache stays in sync after each mutation so synchronous getChords() callers don't
// pay a Ruby round-trip on every read.
let chordsCache = null;

function refreshCache() {
  try {
    const json = window.App.call("$chordManager", "get_chords").toString();
    chordsCache = JSON.parse(json);
  } catch (e) {
    console.error(e);
    chordsCache = {};
  }
}

export function getChords() {
  if (chordsCache === null) refreshCache();
  return chordsCache;
}

export function loadChords() {
  refreshCache();
  return chordsCache;
}

export function saveChords() {
  window.App.call("$chordManager", "set_chords", chordsCache);
}

export function updateChord(name, data) {
  const copy = JSON.parse(JSON.stringify(data));
  chordsCache[name] = copy;
  window.App.call("$chordManager", "update_chord", name, copy);
}

export function deleteChord(name) {
  delete chordsCache[name];
  window.App.call("$chordManager", "delete_chord", name);
}

export function setChords(newChords) {
  chordsCache = newChords || {};
  window.App.call("$chordManager", "set_chords", chordsCache);
  window.dispatchEvent(new Event("chordsUpdated"));
}
