import { getChords, setChords } from "./chord_manager.js";
import { getPresets, setPresets } from "./presets.js";

export function setupProjectManager(App) {
  const saveBtn = document.getElementById("save-project-btn");
  const loadInput = document.getElementById("load-project-input");

  if (!saveBtn || !loadInput) return;

  saveBtn.onclick = async () => {
    try {
      const sequencerJson = App.call("$sequencer", "serialize_project").toString();
      const sequencerData = JSON.parse(sequencerJson);

      const project = {
        version: "1.0",
        timestamp: new Date().toISOString(),
        sequencer: sequencerData,
        chords: getChords(),
        synthPresets: getPresets()
      };

      const blob = new Blob([JSON.stringify(project, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `ruby-synth-project-${new Date().toISOString().slice(0,10)}.json`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    } catch (e) {
      console.error("Failed to save project:", e);
      alert("Failed to save project. Check console for details.");
    }
  };

  loadInput.onchange = (e) => {
    const file = e.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (evt) => {
      try {
        const project = JSON.parse(evt.target.result);
        
        if (project.chords) {
            setChords(project.chords);
        }
        if (project.synthPresets) {
            setPresets(project.synthPresets);
        }
        if (project.sequencer) {
            App.call("$sequencer", "deserialize_project", JSON.stringify(project.sequencer));
        }

        // Force a full re-render of the sequencer so cached track rows and
        // block elements don't linger past the project swap.
        window.dispatchEvent(new Event("projectLoaded"));
        window.dispatchEvent(new Event("trackChanged"));
        
        alert("Project loaded successfully!");

      } catch (err) {
        console.error("Failed to load project:", err);
        alert("Failed to load project file.");
      }
    };
    reader.readAsText(file);
    e.target.value = ""; // Reset input
  };
}
