// The frame maths, mirrored from `framegrab-core`'s `frames.rs`.
//
// The Rust side owns the export; this copy exists so the "≈ N images"
// estimate and the preview grid can update as fast as a slider moves, without
// a round trip. Both are covered by the same table of cases (see
// `frames.test.mjs` and the `#[test]`s in frames.rs) so they can't drift.

export const COUNT_MIN = 1
export const COUNT_MAX = 2000
export const FPS_MIN = 0.5
export const FPS_MAX = 30

/** Ceiling on an FPS-mode sample list, matching the Rust core. */
const FPS_SAFETY_CAP = 10_000

export function clampCount(value) {
  if (!Number.isFinite(value)) return COUNT_MIN
  return Math.min(Math.max(Math.round(value), COUNT_MIN), COUNT_MAX)
}

export function clampFps(value) {
  if (!Number.isFinite(value)) return FPS_MIN
  return Math.min(Math.max(value, FPS_MIN), FPS_MAX)
}

/**
 * The exact timestamps (seconds) that will be sampled for a region.
 * Used by the estimate, the preview grid and — via the same list, sent over
 * IPC — the export itself, so the three can never disagree.
 */
export function frameTimes(start, end, selection) {
  if (!Number.isFinite(start) || !Number.isFinite(end)) return []

  const lo = Math.max(0, Math.min(start, end))
  const hi = Math.max(0, Math.max(start, end))
  const span = Math.max(0, hi - lo)

  if (selection.mode === 'fps') {
    const step = 1 / clampFps(selection.fps)
    const times = []
    let t = lo
    while (t <= hi + 1e-6) {
      times.push(Math.min(t, hi))
      t += step
      if (times.length >= FPS_SAFETY_CAP) break
    }
    return times.length ? times : [lo]
  }

  const n = clampCount(selection.count)
  if (n === 1) return [lo + span / 2]
  return Array.from({ length: n }, (_, i) => lo + (span * i) / (n - 1))
}

/** `M:SS.cc`, the same clock the macOS app shows. */
export function formatTimecode(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00.00'
  const totalCentis = Math.round(seconds * 100)
  const minutes = Math.floor(totalCentis / 6000)
  const secs = Math.floor(totalCentis / 100) % 60
  const centis = totalCentis % 100
  return `${minutes}:${String(secs).padStart(2, '0')}.${String(centis).padStart(2, '0')}`
}
