const { buildTraceModel, parseTarArchive } = window.ZmrTraceParser;

const state = {
  model: null,
  selectedEvent: null,
  selectedFrameIndex: 0,
  replayTimer: null,
  objectUrls: new Map(),
};

const els = {
  bundleInput: document.querySelector("#bundleInput"),
  statusText: document.querySelector("#statusText"),
  scenarioName: document.querySelector("#scenarioName"),
  runStatus: document.querySelector("#runStatus"),
  duration: document.querySelector("#duration"),
  eventCount: document.querySelector("#eventCount"),
  snapshotCount: document.querySelector("#snapshotCount"),
  emptyState: document.querySelector("#emptyState"),
  dropTarget: document.querySelector("#dropTarget"),
  viewerGrid: document.querySelector("#viewerGrid"),
  eventFilter: document.querySelector("#eventFilter"),
  replayPanel: document.querySelector("#replayPanel"),
  replayPrev: document.querySelector("#replayPrev"),
  replayPlay: document.querySelector("#replayPlay"),
  replayNext: document.querySelector("#replayNext"),
  replaySlider: document.querySelector("#replaySlider"),
  replayPosition: document.querySelector("#replayPosition"),
  replayFrameKind: document.querySelector("#replayFrameKind"),
  replayFrameTime: document.querySelector("#replayFrameTime"),
  eventList: document.querySelector("#eventList"),
  detailTitle: document.querySelector("#detailTitle"),
  detailSubtitle: document.querySelector("#detailSubtitle"),
  screenshotMount: document.querySelector("#screenshotMount"),
  screenshotLink: document.querySelector("#screenshotLink"),
  treeLink: document.querySelector("#treeLink"),
  nodeCount: document.querySelector("#nodeCount"),
  nodeList: document.querySelector("#nodeList"),
  selectedNodeJson: document.querySelector("#selectedNodeJson"),
  snapshotJson: document.querySelector("#snapshotJson"),
  payloadJson: document.querySelector("#payloadJson"),
  artifactList: document.querySelector("#artifactList"),
};

els.bundleInput.addEventListener("change", async (event) => {
  const file = event.target.files?.[0];
  if (file) await loadBundleFile(file);
});

els.eventFilter.addEventListener("input", () => renderEvents());
els.replayPrev.addEventListener("click", () => selectReplayFrame(state.selectedFrameIndex - 1));
els.replayNext.addEventListener("click", () => selectReplayFrame(state.selectedFrameIndex + 1));
els.replayPlay.addEventListener("click", () => toggleReplay());
els.replaySlider.addEventListener("input", () => selectReplayFrame(Number.parseInt(els.replaySlider.value, 10)));

for (const eventName of ["dragenter", "dragover"]) {
  els.dropTarget.addEventListener(eventName, (event) => {
    event.preventDefault();
    els.dropTarget.classList.add("dragging");
  });
}

for (const eventName of ["dragleave", "drop"]) {
  els.dropTarget.addEventListener(eventName, (event) => {
    event.preventDefault();
    els.dropTarget.classList.remove("dragging");
  });
}

els.dropTarget.addEventListener("drop", async (event) => {
  const file = event.dataTransfer?.files?.[0];
  if (file) await loadBundleFile(file);
});

async function loadBundleFile(file) {
  await loadBundle(file.name, () => file.arrayBuffer());
}

async function loadBundleFromUrl(url) {
  const name = url.split("/").pop() || url;
  await loadBundle(name, async () => {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Failed to fetch ${url}: HTTP ${response.status}`);
    }
    return await response.arrayBuffer();
  });
}

async function loadBundle(name, getBuffer) {
  setStatus(`Loading ${name}`);
  try {
    stopReplay();
    revokeObjectUrls();
    const entries = parseTarArchive(await getBuffer());
    const model = buildTraceModel(entries);
    state.model = model;
    state.selectedFrameIndex = 0;
    state.selectedEvent = model.replayFrames[0]?.event ?? model.events[0] ?? null;
    renderModel(name);
  } catch (error) {
    console.error(error);
    setStatus(error instanceof Error ? error.message : String(error), true);
  }
}

const bundleParam = new URLSearchParams(window.location.search).get("bundle");
if (bundleParam) {
  loadBundleFromUrl(bundleParam);
}

function renderModel(fileName) {
  const { summary } = state.model;
  els.emptyState.classList.add("hidden");
  els.viewerGrid.classList.remove("hidden");
  els.scenarioName.textContent = summary.scenarioName || "(unnamed)";
  els.runStatus.textContent = summary.status;
  els.runStatus.className = `status ${summary.status}`;
  els.duration.textContent = summary.durationMs == null ? "-" : `${summary.durationMs}ms`;
  els.eventCount.textContent = String(summary.eventCount);
  els.snapshotCount.textContent = String(summary.snapshotCount);
  setStatus(fileName);
  renderEvents();
  renderArtifacts();
  updateReplayControls();
  renderEventDetail(state.selectedEvent);
}

function renderEvents() {
  if (!state.model) return;
  const filter = els.eventFilter.value.trim().toLowerCase();
  const events = state.model.events.filter((event) => {
    if (!filter) return true;
    return `${event.kind} ${JSON.stringify(event.payload ?? {})}`.toLowerCase().includes(filter);
  });

  els.eventList.replaceChildren(
    ...events.map((event) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = event === state.selectedEvent ? "event-row selected" : "event-row";
      button.addEventListener("click", () => {
        selectEvent(event);
      });
      button.innerHTML = `
        <span class="event-seq">${escapeHtml(String(event.seq ?? "-"))}</span>
        <span class="event-kind">${escapeHtml(event.kind ?? "unknown")}</span>
        <span class="event-summary">${escapeHtml(summarizePayload(event.payload))}</span>
      `;
      item.append(button);
      return item;
    }),
  );
}

function selectEvent(event) {
  state.selectedEvent = event;
  const frameIndex = state.model.replayFrames.findIndex((frame) => frame.event === event);
  if (frameIndex >= 0) state.selectedFrameIndex = frameIndex;
  renderEvents();
  updateReplayControls();
  renderEventDetail(event);
}

function selectReplayFrame(index) {
  if (!state.model) return;
  const frames = state.model.replayFrames;
  if (frames.length === 0) return;
  const clamped = Math.max(0, Math.min(frames.length - 1, Number.isFinite(index) ? index : 0));
  state.selectedFrameIndex = clamped;
  state.selectedEvent = frames[clamped].event;
  renderEvents();
  updateReplayControls();
  renderEventDetail(state.selectedEvent);
  els.eventList.querySelector(".event-row.selected")?.scrollIntoView({ block: "nearest" });
}

function toggleReplay() {
  if (state.replayTimer) {
    stopReplay();
    updateReplayControls();
    return;
  }
  if (!state.model || state.model.replayFrames.length === 0) return;
  if (state.selectedFrameIndex >= state.model.replayFrames.length - 1) selectReplayFrame(0);
  state.replayTimer = window.setInterval(() => {
    if (!state.model || state.selectedFrameIndex >= state.model.replayFrames.length - 1) {
      stopReplay();
      updateReplayControls();
      return;
    }
    selectReplayFrame(state.selectedFrameIndex + 1);
  }, 900);
  updateReplayControls();
}

function stopReplay() {
  if (!state.replayTimer) return;
  window.clearInterval(state.replayTimer);
  state.replayTimer = null;
}

function updateReplayControls() {
  const frames = state.model?.replayFrames ?? [];
  if (frames.length === 0) {
    els.replayPanel.classList.add("hidden");
    stopReplay();
    return;
  }

  const frame = frames[state.selectedFrameIndex] ?? frames[0];
  els.replayPanel.classList.remove("hidden");
  els.replaySlider.max = String(Math.max(0, frames.length - 1));
  els.replaySlider.value = String(frame.index);
  els.replayPrev.disabled = frame.index === 0;
  els.replayNext.disabled = frame.index === frames.length - 1;
  els.replayPlay.textContent = state.replayTimer ? "Ⅱ" : "▶";
  els.replayPlay.title = state.replayTimer ? "Pause" : "Play";
  els.replayPlay.setAttribute("aria-label", state.replayTimer ? "Pause" : "Play");
  els.replayPosition.textContent = `${frame.index + 1} / ${frames.length}`;
  els.replayFrameKind.textContent = frame.kind;
  els.replayFrameTime.textContent = frame.elapsedMs == null ? "-" : `${frame.elapsedMs}ms`;
}

function renderArtifacts() {
  const artifacts = state.model.artifacts;
  els.artifactList.replaceChildren(
    ...artifacts.map((artifact) => {
      const item = document.createElement("li");
      const link = document.createElement("a");
      link.href = objectUrlForEntry(artifact.entry);
      link.target = "_blank";
      link.rel = "noreferrer";
      link.textContent = artifact.path;
      item.append(link);
      return item;
    }),
  );
}

function renderEventDetail(event) {
  if (!event) return;
  els.detailTitle.textContent = event.kind ?? "Event Detail";
  const frame = state.model.replayFrames[state.selectedFrameIndex];
  const frameText = frame?.event === event ? ` · frame ${frame.index + 1}/${state.model.replayFrames.length}` : "";
  els.detailSubtitle.textContent = `seq ${event.seq ?? "-"}${frameText}`;
  els.payloadJson.textContent = pretty(event.payload ?? {});

  const snapshotId = snapshotIdForEvent(event);
  const inspection = snapshotId ? state.model.snapshotInspections.get(snapshotId) : null;
  const snapshot = inspection?.snapshot ?? null;
  els.snapshotJson.textContent = snapshot ? pretty(snapshot) : "{}";
  renderScreenshot(inspection);
  renderTree(inspection);
}

function snapshotIdForEvent(event) {
  if (event.payload?.snapshotId) return event.payload.snapshotId;
  if (event.payload?.afterSnapshotId) return event.payload.afterSnapshotId;
  if (event.payload?.beforeSnapshotId) return event.payload.beforeSnapshotId;
  if (typeof event.payload?.value === "string") {
    const match = event.payload.value.match(/(?:^|\/)(snapshot-[^/.]+)\.json$/);
    if (match) return match[1];
  }
  return null;
}

function renderScreenshot(inspection) {
  els.screenshotMount.replaceChildren();
  els.screenshotLink.classList.add("hidden");
  if (!inspection) {
    els.screenshotMount.append(emptyText("No screenshot selected"));
    return;
  }
  const imageArtifact = inspection.screenshot;
  if (!imageArtifact) {
    els.screenshotMount.append(emptyText("No screenshot artifact"));
    return;
  }
  const url = objectUrlForEntry(imageArtifact.entry);
  const img = document.createElement("img");
  img.src = url;
  img.alt = `Screenshot ${inspection.id}`;
  img.addEventListener("error", () => {
    els.screenshotMount.replaceChildren(emptyText("Screenshot artifact is not a valid image"));
  });
  els.screenshotMount.append(img);
  els.screenshotLink.href = url;
  els.screenshotLink.classList.remove("hidden");
}

function renderTree(inspection) {
  els.nodeList.replaceChildren();
  els.selectedNodeJson.textContent = "{}";
  els.nodeCount.textContent = inspection?.nodes ? `${inspection.nodes.length} nodes` : "0 nodes";
  els.treeLink.classList.add("hidden");

  if (!inspection) {
    els.nodeList.append(emptyListItem("No snapshot selected"));
    return;
  }

  if (inspection.tree) {
    els.treeLink.href = objectUrlForEntry(inspection.tree.entry);
    els.treeLink.classList.remove("hidden");
  }

  if (inspection.nodes.length === 0) {
    els.nodeList.append(emptyListItem("No nodes in snapshot"));
    return;
  }

  const items = inspection.nodes.map((node, index) => {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "node-row";
    button.addEventListener("click", () => {
      for (const row of els.nodeList.querySelectorAll(".node-row")) row.classList.remove("selected");
      button.classList.add("selected");
      els.selectedNodeJson.textContent = pretty(node.raw);
    });

    const meta = [
      node.className,
      node.resourceId ? `#${node.resourceId}` : "",
      node.bounds ? `${node.bounds.x},${node.bounds.y} ${node.bounds.width}x${node.bounds.height}` : "",
    ].filter(Boolean).join(" · ");

    button.innerHTML = `
      <span class="node-label">${escapeHtml(node.label || node.stableId || `node ${index + 1}`)}</span>
      <span class="node-meta">${escapeHtml(meta || node.stableId || "")}</span>
    `;
    item.append(button);
    return item;
  });
  els.nodeList.replaceChildren(...items);
  items[0]?.querySelector("button")?.click();
}

function emptyListItem(text) {
  const item = document.createElement("li");
  item.append(emptyText(text));
  return item;
}

function objectUrlForEntry(entry) {
  if (state.objectUrls.has(entry.path)) return state.objectUrls.get(entry.path);
  const blob = new Blob([entry.bytes], { type: entry.mime });
  const url = URL.createObjectURL(blob);
  state.objectUrls.set(entry.path, url);
  return url;
}

function revokeObjectUrls() {
  for (const url of state.objectUrls.values()) URL.revokeObjectURL(url);
  state.objectUrls.clear();
}

function setStatus(message, failed = false) {
  els.statusText.textContent = message;
  els.statusText.classList.toggle("failed", failed);
}

function summarizePayload(payload) {
  if (!payload) return "";
  if (payload.status) return payload.status;
  if (payload.error) return payload.error;
  if (payload.value) return payload.value;
  if (payload.snapshotId) return payload.snapshotId;
  return JSON.stringify(payload).slice(0, 120);
}

function pretty(value) {
  return JSON.stringify(value, null, 2);
}

function emptyText(text) {
  const span = document.createElement("span");
  span.textContent = text;
  return span;
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[char]);
}
