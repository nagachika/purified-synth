// Thin wrappers around Ruby-side $presets (source of truth in localStorage).
// Cache stays in sync after each mutation so synchronous getPresets() callers don't
// pay a Ruby round-trip on every read.
let presetsCache = null;

function refreshCache() {
  try {
    const json = window.App.call("$presets", "get_presets").toString();
    presetsCache = JSON.parse(json);
  } catch (e) {
    console.error(e);
    presetsCache = {};
  }
}

export function getPresets() {
  if (presetsCache === null) refreshCache();
  return presetsCache;
}

window.getPresets = getPresets;

export function setPresets(newPresets) {
  presetsCache = newPresets || {};
  window.App.call("$presets", "set_presets", presetsCache);
  window.dispatchEvent(new Event("presetsUpdated"));
}

function savePresets(presets) {
  presetsCache = presets;
  window.App.call("$presets", "set_presets", presets);
  window.dispatchEvent(new Event("presetsUpdated"));
}

export function updateUIFromSettings(json) {
    try {
      const data = JSON.parse(json);
      for (const [key, val] of Object.entries(data)) {
        const el = document.getElementById(key);
        if (el) {
            if (el.type === "checkbox") {
              el.checked = val;
            } else {
              el.value = val;
            }
            const display = document.getElementById(`val_${key}`);
            if (display) {
              let text = val;
              if (key === 'cutoff') text += ' Hz';
              if (key.includes('time') || key.includes('attack') || key.includes('decay') || key.includes('release') || key.includes('seconds')) text += ' s';
              if (key === 'lfo_rate') text += ' Hz';
              display.textContent = text;
            }
        }
      }
    } catch(e) { console.error(e); }
  }

export function setupPresets(App) {
  const nameInput = document.getElementById("preset_name");
  const saveBtn = document.getElementById("save_preset");
  const listSelect = document.getElementById("preset_list");
  const loadBtn = document.getElementById("load_preset");
  const deleteBtn = document.getElementById("delete_preset");

  function updateList() {
    const presets = getPresets();
    listSelect.innerHTML = '<option value="">-- Select Preset --</option>';
    Object.keys(presets).forEach(name => {
      const opt = document.createElement("option");
      opt.value = name;
      opt.textContent = name;
      listSelect.appendChild(opt);
    });
  }
  updateList();

  window.addEventListener("presetsUpdated", updateList);

  saveBtn.onclick = () => {
    const name = nameInput.value.trim();
    if (!name) return alert("Please enter a preset name.");
    try {
      // Always save the full patch structure (works for both legacy-style and custom)
      const json = App.call("$synth", "export_patch").toString();
      const presets = getPresets();
      presets[name] = json;
      savePresets(presets);
      alert(`Preset "${name}" saved!`);
      nameInput.value = "";
      updateList();
    } catch(e) { console.error(e); }
  };
  loadBtn.onclick = () => {
    const name = listSelect.value;
    if (!name) return;
    const presets = getPresets();
    if (presets[name]) {
        const json = presets[name];
        try {
            const data = JSON.parse(json);
            if (data.nodes) {
                // New Modular Patch Format
                App.call("$synth", "import_patch", json);
                if (window.modularEditor) {
                    window.modularEditor.loadPatch(data);
                }
            } else {
                console.warn("Legacy preset format is no longer supported.");
            }
        } catch(e) { console.error(e); }
    }
  };
  deleteBtn.onclick = () => {
    const name = listSelect.value;
    if (name && confirm(`Delete preset "${name}"?`)) {
        const presets = getPresets();
        delete presets[name];
        savePresets(presets);
        updateList();
    }
  };
}
