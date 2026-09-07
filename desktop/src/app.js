// FrameGrab's window: the same editor as the macOS app — player, timeline with
// an in/out region, contact-sheet preview and an export panel — driven from a
// single state object.
//
// Anything that decides *what* gets exported lives in frames.js (mirrored from
// the Rust core); anything that touches a file goes through a Tauri command.

import { COUNT_MAX, COUNT_MIN, FPS_MAX, FPS_MIN, clampCount, clampFps, formatTimecode, frameTimes } from './frames.js'

const { core, event, dialog } = window.__TAURI__
const { invoke, convertFileSrc } = core

/** Rendering hundreds of thumbnails is pointless (and slow) — cap the grid. */
const MAX_PREVIEW_FRAMES = 60
const PRESETS = [8, 12, 16, 24]
const VIDEO_EXTENSIONS = ['mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi', 'mpg', 'mpeg', 'wmv', 'flv']

const state = {
  toolsReady: true,
  videoPath: null,
  info: null, // { duration, width, height }
  selectionStart: 0,
  selectionEnd: 0,
  currentTime: 0,
  canPlayInline: true,
  filmstrip: [],
  settings: {
    mode: 'count',
    fps: 2,
    count: 12,
    format: 'png',
    jpegQuality: 0.9,
    maxWidth: null,
    outputMode: 'zip',
  },
  exportName: '',
  resolvedName: 'frames',
  defaultName: 'frames',
  plannedTimes: [],
  excluded: new Set(),
  previewVisible: false,
  previewImages: [],
  previewRendering: false,
  exporting: false,
  progress: 0,
}

const el = new Proxy({}, { get: (_, id) => document.getElementById(String(id).replace(/_/g, '-')) })

// ---------------------------------------------------------------- derived

const plannedCount = () => state.plannedTimes.length
const includedCount = () => Math.max(0, plannedCount() - state.excluded.size)
const exportTimes = () => state.plannedTimes.filter((_, i) => !state.excluded.has(i))
const hasVideo = () => state.videoPath !== null && state.info !== null

/** Recomputed whenever the region or the frame settings change. */
function recomputePlannedTimes() {
  const times = state.info ? frameTimes(state.selectionStart, state.selectionEnd, state.settings) : []
  const unchanged =
    times.length === state.plannedTimes.length && times.every((t, i) => t === state.plannedTimes[i])
  if (unchanged) return

  state.plannedTimes = times
  // The indices no longer point at the same frames.
  state.excluded.clear()
  schedulePreviewRefresh()
}

// ---------------------------------------------------------------- video

async function openVideo() {
  const selected = await dialog.open({
    multiple: false,
    filters: [{ name: 'Video', extensions: VIDEO_EXTENSIONS }],
  })
  if (typeof selected === 'string') loadVideo(selected)
}

async function loadVideo(path) {
  try {
    const info = await invoke('probe_video', { path })
    state.videoPath = path
    state.info = info
    state.selectionStart = 0
    state.selectionEnd = info.duration
    state.currentTime = 0
    state.filmstrip = new Array(16).fill(null)
    state.excluded.clear()
    state.previewImages = []
    state.previewVisible = false
    state.canPlayInline = true
    // Clear the typed name so the field re-derives from the new video.
    state.exportName = ''
    el.name_input.value = ''
    state.defaultName = await invoke('default_export_name', { path })
    el.name_input.placeholder = state.defaultName

    el.video.src = convertFileSrc(path)
    el.video.load()

    recomputePlannedTimes()
    refreshResolvedName()
    renderFilmstrip()
    render()
  } catch (error) {
    showError('Couldn’t open that video', String(error))
  }
}

function renderFilmstrip() {
  if (!state.info) return
  const count = 16
  // Lay the slots out up front so the strip doesn't reflow as frames arrive.
  el.filmstrip.replaceChildren(
    ...Array.from({ length: count }, () => {
      const img = document.createElement('img')
      img.alt = ''
      return img
    })
  )
  const times = Array.from({ length: count }, (_, i) => (state.info.duration * (i + 0.5)) / count)
  invoke('render_thumbnails', {
    channel: 'filmstrip',
    path: state.videoPath,
    times,
    maxWidth: 160,
  })
}

function seek(seconds) {
  if (!state.info) return
  const clamped = Math.max(0, Math.min(state.info.duration, seconds))
  state.currentTime = clamped
  if (state.canPlayInline) {
    el.video.currentTime = clamped
  } else {
    refreshFallbackFrame(clamped)
  }
  renderTransport()
  renderTimeline()
}

/** When the webview can't decode the file, scrubbing shows an ffmpeg still.
 *  Each request supersedes the last on the channel, so a fast scrub doesn't
 *  queue up dozens of renders. */
function refreshFallbackFrame(seconds) {
  invoke('render_thumbnails', {
    channel: 'fallback',
    path: state.videoPath,
    times: [seconds],
    maxWidth: 960,
  }).catch(() => {})
}

// ---------------------------------------------------------------- preview

let previewTimer = null

function schedulePreviewRefresh() {
  clearTimeout(previewTimer)
  invoke('cancel_thumbnails', { channel: 'preview' }).catch(() => {})

  if (!state.previewVisible || !state.info) {
    state.previewImages = []
    state.previewRendering = false
    rebuildPreviewGrid()
    return
  }

  const times = state.plannedTimes.slice(0, MAX_PREVIEW_FRAMES)
  state.previewImages = new Array(times.length).fill(null)
  state.previewRendering = times.length > 0
  rebuildPreviewGrid()
  if (!times.length) return

  // Dragging a slider shouldn't kick off a render per tick.
  previewTimer = setTimeout(() => {
    invoke('render_thumbnails', {
      channel: 'preview',
      path: state.videoPath,
      times,
      maxWidth: 480,
    })
  }, 250)
}

function togglePreview() {
  state.previewVisible = !state.previewVisible
  schedulePreviewRefresh()
  render()
  rebuildPreviewGrid()
}

function toggleExclusion(index) {
  if (state.excluded.has(index)) state.excluded.delete(index)
  else state.excluded.add(index)
  renderPreviewChrome()
  renderEstimate()
  renderExportButton()
}

// ---------------------------------------------------------------- export

async function startExport() {
  if (!hasVideo() || state.exporting) return
  const times = exportTimes()
  if (!times.length) {
    showError('Nothing to export', 'Every frame is excluded — include at least one frame to export.')
    return
  }

  const name = state.resolvedName
  let destination
  if (state.settings.outputMode === 'zip') {
    destination = await dialog.save({
      defaultPath: `${name}.zip`,
      filters: [{ name: 'Zip archive', extensions: ['zip'] }],
    })
  } else {
    destination = await dialog.open({ directory: true, multiple: false })
  }
  if (typeof destination !== 'string') return

  state.exporting = true
  state.progress = 0
  render()

  try {
    const outcome = await invoke('export_frames', {
      request: {
        input: state.videoPath,
        times,
        source: state.info,
        options: {
          format: state.settings.format,
          jpegQuality: state.settings.jpegQuality,
          maxWidth: state.settings.maxWidth,
        },
        outputMode: state.settings.outputMode,
        destination,
        name,
      },
    })
    // Showing the result is a nicety on top of a finished export — a machine
    // with no file manager to open must not turn success into an error.
    if (!outcome.cancelled) await invoke('reveal', { path: outcome.path }).catch(() => {})
  } catch (error) {
    showError('The export didn’t finish', String(error))
  } finally {
    state.exporting = false
    state.progress = 0
    render()
  }
}

// ---------------------------------------------------------------- rendering

function render() {
  const ready = hasVideo()
  el.empty_state.hidden = ready
  el.player.hidden = !ready || state.previewVisible
  el.preview.hidden = !ready || !state.previewVisible
  el.timeline.hidden = !ready

  renderTransport()
  renderTimeline()
  renderFrameControls()
  renderFormatControls()
  renderOutputControls()
  renderEstimate()
  renderPreviewChrome()
  renderExportButton()
}

function renderTransport() {
  el.current_time.textContent = formatTimecode(state.currentTime)
  el.duration.textContent = formatTimecode(state.info?.duration ?? 0)
  el.play.textContent = el.video.paused ? 'Play' : 'Pause'
  // Nothing to play when the webview can't decode the file — the fallback
  // stills are scrubbed with the timeline instead.
  el.play.disabled = !hasVideo() || !state.canPlayInline
  el.video.hidden = !state.canPlayInline
  el.video_fallback.hidden = state.canPlayInline
}

function renderTimeline() {
  if (!state.info) return
  const duration = state.info.duration || 1
  const percent = (seconds) => `${Math.max(0, Math.min(100, (seconds / duration) * 100))}%`

  el.selection.style.left = percent(state.selectionStart)
  el.selection.style.width = `${Math.max(0, ((state.selectionEnd - state.selectionStart) / duration) * 100)}%`
  el.handle_in.style.left = percent(state.selectionStart)
  el.handle_out.style.left = percent(state.selectionEnd)
  el.playhead.style.left = percent(state.currentTime)

  el.label_in.textContent = formatTimecode(state.selectionStart)
  el.label_out.textContent = formatTimecode(state.selectionEnd)
  el.label_length.textContent = `${formatTimecode(Math.max(0, state.selectionEnd - state.selectionStart))} selected`
}

function renderFrameControls() {
  const isFps = state.settings.mode === 'fps'
  el.fps_controls.hidden = !isFps
  el.count_controls.hidden = isFps

  for (const button of el.mode_picker.children) {
    button.classList.toggle('active', button.dataset.mode === state.settings.mode)
  }
  if (document.activeElement !== el.count_input) el.count_input.value = String(state.settings.count)
  if (document.activeElement !== el.fps_input) el.fps_input.value = formatFps(state.settings.fps)
  el.fps_slider.value = String(state.settings.fps)

  for (const button of el.presets.children) {
    button.classList.toggle('active', Number(button.dataset.value) === state.settings.count)
  }
}

function renderFormatControls() {
  for (const button of el.format_picker.children) {
    button.classList.toggle('active', button.dataset.format === state.settings.format)
  }
  el.quality_controls.hidden = state.settings.format !== 'jpeg'
  el.quality_value.textContent = `${Math.round(state.settings.jpegQuality * 100)}%`
  el.scale_select.value = state.settings.maxWidth ? String(state.settings.maxWidth) : ''
}

function renderOutputControls() {
  for (const button of el.output_picker.children) {
    button.classList.toggle('active', button.dataset.output === state.settings.outputMode)
  }
  el.output_caption.textContent =
    state.settings.outputMode === 'zip'
      ? `Saves one archive: ${state.resolvedName}.zip`
      : `Creates a folder: ${state.resolvedName}`
}

function renderEstimate() {
  const included = includedCount()
  const excluded = plannedCount() - included
  el.estimate_count.textContent = `${included} image${included === 1 ? '' : 's'}`
  el.estimate_excluded.hidden = excluded <= 0
  el.estimate_excluded.textContent = `${excluded} excluded in preview`
  el.estimate_warning.hidden = included <= 20
  el.toggle_preview.textContent = state.previewVisible ? 'Hide preview' : 'Preview frames'
  el.toggle_preview.disabled = !hasVideo() || plannedCount() === 0
}

/** Header counts and per-tile include state — cheap enough to run often. */
function renderPreviewChrome() {
  el.preview_spinner.hidden = !state.previewRendering
  el.preview_count.textContent = `${includedCount()} of ${plannedCount()} selected`
  el.include_all.hidden = state.excluded.size === 0
  el.preview_truncated.hidden = plannedCount() <= MAX_PREVIEW_FRAMES
  el.preview_truncated.textContent = `Previewing the first ${MAX_PREVIEW_FRAMES} of ${plannedCount()} frames — the rest are still exported, but can’t be excluded individually here.`

  for (const [index, tile] of [...el.preview_grid.children].entries()) {
    const excluded = state.excluded.has(index)
    tile.classList.toggle('excluded', excluded)
    tile.title = excluded ? 'Excluded — click to include' : 'Click to exclude from the export'
  }
}

/** Rebuilds the tiles themselves. Only called when the planned frames change —
 *  a thumbnail arriving just fills in the image it belongs to, so the grid
 *  doesn't flicker or lose its scroll position 60 times over. */
function rebuildPreviewGrid() {
  if (!state.previewVisible) {
    el.preview_grid.replaceChildren()
    return
  }
  const aspect = state.info && state.info.height ? state.info.width / state.info.height : 16 / 9

  el.preview_grid.replaceChildren(
    ...state.previewImages.map((dataUrl, index) => {
      const tile = document.createElement('div')
      tile.className = 'tile'
      tile.onclick = () => toggleExclusion(index)

      const frame = document.createElement('div')
      frame.className = 'tile-image'
      frame.style.aspectRatio = String(aspect)

      const img = document.createElement('img')
      img.alt = ''
      img.hidden = !dataUrl
      if (dataUrl) img.src = dataUrl
      frame.append(img)

      const locate = document.createElement('button')
      locate.className = 'locate'
      locate.textContent = '⌖'
      locate.title = 'Jump the playhead to this frame'
      locate.onclick = (e) => {
        e.stopPropagation()
        seek(state.plannedTimes[index])
      }
      frame.append(locate)

      const meta = document.createElement('div')
      meta.className = 'tile-meta'
      const number = document.createElement('span')
      number.className = 'tile-index'
      number.textContent = String(index + 1)
      const stamp = document.createElement('span')
      stamp.textContent = formatTimecode(state.plannedTimes[index])
      meta.append(number, stamp)

      tile.append(frame, meta)
      return tile
    })
  )
  renderPreviewChrome()
}

function updatePreviewTile(index, dataUrl) {
  const img = el.preview_grid.children[index]?.querySelector('img')
  if (!img) return
  img.src = dataUrl
  img.hidden = false
}

function renderExportButton() {
  const n = includedCount()
  el.export_progress.hidden = !state.exporting
  el.export.hidden = state.exporting
  el.progress_bar.value = state.progress
  el.progress_label.textContent = `${Math.round(state.progress * 100)}%`

  el.export.disabled = !hasVideo() || n === 0
  if (n === 0) {
    el.export.textContent = 'Nothing to export'
  } else {
    const noun = n === 1 ? 'Image' : 'Images'
    el.export.textContent =
      state.settings.outputMode === 'zip' ? `Export ${n} ${noun} as ZIP…` : `Export ${n} ${noun}…`
  }
}

function formatFps(value) {
  return Number.isInteger(value) ? String(value) : value.toFixed(1)
}

function showError(title, message) {
  el.error_title.textContent = title
  el.error_message.textContent = message
  el.error_dialog.showModal()
}

// ---------------------------------------------------------------- name field

let nameTimer = null

/** The authoritative name comes from Rust, so the caption always shows what
 *  will really be written — including any characters it had to replace. */
function refreshResolvedName() {
  clearTimeout(nameTimer)
  nameTimer = setTimeout(async () => {
    state.resolvedName = await invoke('resolve_export_name', {
      typed: state.exportName,
      fallback: state.defaultName,
    })
    renderOutputControls()
  }, 120)
}

// ---------------------------------------------------------------- wiring

function wireFrameControls() {
  el.presets.replaceChildren(
    ...PRESETS.map((value) => {
      const button = document.createElement('button')
      button.textContent = String(value)
      button.dataset.value = String(value)
      button.onclick = () => setCount(value)
      return button
    })
  )

  for (const button of el.mode_picker.children) {
    button.onclick = () => {
      state.settings.mode = button.dataset.mode
      recomputePlannedTimes()
      render()
    }
  }

  // `change` covers both Enter and clicking away, so a half-typed number never
  // reaches the model — the preview isn't rebuilt on every keystroke.
  el.count_input.onchange = () => {
    const digits = el.count_input.value.replace(/[^0-9]/g, '')
    if (!digits) {
      el.count_input.value = String(state.settings.count)
      return
    }
    // More digits than a number can hold clearly means "as many as possible".
    setCount(clampCount(Number(digits) || COUNT_MAX))
  }
  el.count_up.onclick = () => setCount(state.settings.count + 1)
  el.count_down.onclick = () => setCount(state.settings.count - 1)

  el.fps_input.onchange = () => {
    const typed = Number(el.fps_input.value.trim().replace(',', '.'))
    if (!Number.isFinite(typed)) {
      el.fps_input.value = formatFps(state.settings.fps)
      return
    }
    // One decimal place: finer than the slider's step, still readable.
    setFps(Math.round(clampFps(typed) * 10) / 10)
  }
  el.fps_slider.oninput = () => setFps(Number(el.fps_slider.value))
}

function setCount(value) {
  state.settings.count = clampCount(value)
  recomputePlannedTimes()
  renderFrameControls()
  renderEstimate()
  renderExportButton()
}

function setFps(value) {
  state.settings.fps = clampFps(value)
  recomputePlannedTimes()
  renderFrameControls()
  renderEstimate()
  renderExportButton()
}

function wireFormatControls() {
  for (const button of el.format_picker.children) {
    button.onclick = () => {
      state.settings.format = button.dataset.format
      renderFormatControls()
    }
  }
  el.quality_slider.oninput = () => {
    state.settings.jpegQuality = Number(el.quality_slider.value) / 100
    renderFormatControls()
  }
  el.scale_select.onchange = () => {
    const value = el.scale_select.value
    state.settings.maxWidth = value ? Number(value) : null
  }
}

function wireOutputControls() {
  for (const button of el.output_picker.children) {
    button.onclick = () => {
      state.settings.outputMode = button.dataset.output
      renderOutputControls()
      renderExportButton()
    }
  }
  el.name_input.oninput = () => {
    state.exportName = el.name_input.value
    refreshResolvedName()
  }
}

function wireTimeline() {
  const positionToTime = (clientX) => {
    const rect = el.track.getBoundingClientRect()
    const ratio = (clientX - rect.left) / rect.width
    return Math.max(0, Math.min(1, ratio)) * (state.info?.duration ?? 0)
  }

  const drag = (handle, apply) => {
    handle.onpointerdown = (down) => {
      down.stopPropagation()
      handle.setPointerCapture(down.pointerId)
      const move = (e) => {
        apply(positionToTime(e.clientX))
        renderTimeline()
        recomputePlannedTimes()
        renderEstimate()
        renderExportButton()
      }
      const up = () => {
        handle.removeEventListener('pointermove', move)
        handle.removeEventListener('pointerup', up)
      }
      handle.addEventListener('pointermove', move)
      handle.addEventListener('pointerup', up)
      move(down)
    }
  }

  drag(el.handle_in, (t) => { state.selectionStart = Math.min(t, state.selectionEnd) })
  drag(el.handle_out, (t) => { state.selectionEnd = Math.max(t, state.selectionStart) })

  el.track.onpointerdown = (e) => seek(positionToTime(e.clientX))

  el.set_in.onclick = () => {
    state.selectionStart = Math.min(state.currentTime, state.selectionEnd)
    recomputePlannedTimes()
    render()
  }
  el.set_out.onclick = () => {
    state.selectionEnd = Math.max(state.currentTime, state.selectionStart)
    recomputePlannedTimes()
    render()
  }
  el.reset_selection.onclick = () => {
    state.selectionStart = 0
    state.selectionEnd = state.info?.duration ?? 0
    recomputePlannedTimes()
    render()
  }
}

function wireVideo() {
  el.video.onplay = renderTransport
  el.video.onpause = renderTransport
  el.video.ontimeupdate = () => {
    state.currentTime = el.video.currentTime
    renderTransport()
    renderTimeline()
  }
  el.video.onerror = () => {
    // The webview can't decode this codec — fall back to ffmpeg stills so the
    // clip is still usable.
    state.canPlayInline = false
    renderTransport()
    refreshFallbackFrame(state.currentTime)
  }
  el.play.onclick = () => {
    if (!state.canPlayInline) return
    if (el.video.paused) el.video.play()
    else el.video.pause()
  }
  document.addEventListener('keydown', (e) => {
    if (e.code !== 'Space' || e.target.matches('input, select, textarea')) return
    e.preventDefault()
    el.play.click()
  })
}

function wireThumbnails() {
  event.listen('filmstrip', ({ payload }) => {
    if (payload.done) return
    state.filmstrip[payload.index] = payload.dataUrl
    const slot = el.filmstrip.children[payload.index]
    if (slot) slot.src = payload.dataUrl
  })

  event.listen('preview', ({ payload }) => {
    if (payload.done) {
      state.previewRendering = false
      el.preview_spinner.hidden = true
      return
    }
    state.previewImages[payload.index] = payload.dataUrl
    if (state.previewVisible) updatePreviewTile(payload.index, payload.dataUrl)
  })

  event.listen('fallback', ({ payload }) => {
    if (payload.done) return
    el.fallback_frame.src = payload.dataUrl
  })

  event.listen('export-progress', ({ payload }) => {
    state.progress = payload.total ? payload.done / payload.total : 0
    el.progress_bar.value = state.progress
    el.progress_label.textContent = `${Math.round(state.progress * 100)}%`
  })
}

function wireDragAndDrop() {
  event.listen('tauri://drag-enter', () => { el.drop_overlay.hidden = false })
  event.listen('tauri://drag-leave', () => { el.drop_overlay.hidden = true })
  event.listen('tauri://drag-drop', ({ payload }) => {
    el.drop_overlay.hidden = true
    const path = payload?.paths?.[0]
    if (path) loadVideo(path)
  })
}

async function checkTools() {
  const status = await invoke('check_tools')
  state.toolsReady = status.available
  el.setup_banner.hidden = status.available
  el.setup_message.textContent =
    'FrameGrab needs ffmpeg to read video. Install it (macOS: brew install ffmpeg · Windows: winget install Gyan.FFmpeg), or put ffmpeg and ffprobe next to the app.'
  el.open_video.disabled = !status.available
}

function main() {
  wireFrameControls()
  wireFormatControls()
  wireOutputControls()
  wireTimeline()
  wireVideo()
  wireThumbnails()
  wireDragAndDrop()

  el.open_video.onclick = openVideo
  el.toggle_preview.onclick = togglePreview
  el.close_preview.onclick = togglePreview
  el.include_all.onclick = () => {
    state.excluded.clear()
    renderPreviewChrome()
    renderEstimate()
    renderExportButton()
  }
  el.export.onclick = startExport
  el.cancel_export.onclick = () => invoke('cancel_export')
  el.setup_recheck.onclick = checkTools

  checkTools()
  render()
}

main()
