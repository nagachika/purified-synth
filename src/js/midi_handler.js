export function setupMIDI(App, getTabState) {
  const statusEl = document.getElementById("midi-status");

  if (!navigator.requestMIDIAccess) {
    if (statusEl) statusEl.textContent = "MIDI: 非対応";
    return;
  }

  navigator.requestMIDIAccess().then(access => {
    updateStatus(access, statusEl);

    const onMessage = (e) => {
      const [status, data1 = 0, data2 = 0] = e.data;
      let actionJson;
      try {
        actionJson = App.call("$midiProcessor", "process", status, data1, data2);
      } catch(_) { return; }
      const action = JSON.parse(actionJson.toString());
      handleAction(action, getTabState());
    };

    for (const input of access.inputs.values()) {
      input.onmidimessage = onMessage;
    }

    access.onstatechange = () => {
      updateStatus(access, statusEl);
      for (const input of access.inputs.values()) {
        input.onmidimessage = onMessage;
      }
    };
  }).catch(() => {
    if (statusEl) statusEl.textContent = "MIDI: アクセス拒否";
  });
}

function updateStatus(access, el) {
  if (!el) return;
  const names = [...access.inputs.values()].map(i => i.name).join(", ");
  el.textContent = names ? `MIDI: ${names}` : "MIDI: --";
}

function handleAction(action, tabState) {
  if (!tabState) return;
  switch (action.type) {
    case "re_render_chord":
      if (action.dimension !== undefined) tabState.setChordDimension(action.dimension);
      tabState.reRenderChord();
      break;
    case "re_render_seq":
      if (action.dimension !== undefined) tabState.setSeqDimension(action.dimension);
      tabState.reRenderSeq();
      break;
    case "set_synth_dimension":
      if (action.dimension !== undefined) tabState.setSynthDimension(action.dimension);
      break;
    case "update_master_volume": {
      const slider = document.getElementById("seq-master-volume");
      if (slider) {
        slider.value = action.value;
        slider.dispatchEvent(new Event("input"));
      }
      break;
    }
  }
}
