// Run with `npm test`. These mirror the `#[test]`s in core/src/frames.rs, so a
// change to one side that isn't made to the other shows up as a failure here.
import test from 'node:test'
import assert from 'node:assert/strict'
import { frameTimes, formatTimecode, clampCount, clampFps, COUNT_MAX, COUNT_MIN, FPS_MIN } from '../src/frames.js'

const count = (c) => ({ mode: 'count', fps: 2, count: c })
const fps = (f) => ({ mode: 'fps', fps: f, count: 12 })

test('count spans the region end to end', () => {
  assert.deepEqual(frameTimes(2, 6, count(5)), [2, 3, 4, 5, 6])
})

test('a single frame lands in the middle', () => {
  assert.deepEqual(frameTimes(0, 10, count(1)), [5])
})

test('count is capped rather than trusted', () => {
  assert.equal(frameTimes(0, 10, count(999999)).length, COUNT_MAX)
  assert.equal(frameTimes(0, 10, count(0)).length, COUNT_MIN)
})

test('fps steps by the rate and never passes the end', () => {
  const times = frameTimes(0, 2, fps(2))
  assert.deepEqual(times, [0, 0.5, 1, 1.5, 2])
  assert.ok(times.every((t) => t <= 2))
})

test('fps is capped so a long clip cannot run away', () => {
  assert.equal(frameTimes(0, 36000, fps(30)).length, 10000)
})

test('a reversed selection is read the right way round', () => {
  assert.deepEqual(frameTimes(6, 2, count(5)), frameTimes(2, 6, count(5)))
})

test('an empty region still yields frames at that instant', () => {
  assert.deepEqual(frameTimes(3, 3, count(4)), [3, 3, 3, 3])
  assert.deepEqual(frameTimes(3, 3, fps(2)), [3])
})

test('nonsense input produces no frames instead of throwing', () => {
  assert.deepEqual(frameTimes(NaN, 5, count(4)), [])
  assert.deepEqual(frameTimes(0, Infinity, count(4)), [])
})

test('a nonsense rate falls back to the slowest allowed', () => {
  assert.equal(clampFps(NaN), FPS_MIN)
  assert.ok(frameTimes(0, 4, fps(NaN)).length > 0)
})

test('clamping matches the Rust ranges', () => {
  assert.equal(clampCount(-5), 1)
  assert.equal(clampCount(5000), 2000)
  assert.equal(clampFps(0), 0.5)
  assert.equal(clampFps(99), 30)
})

test('timecode formatting matches the macOS app', () => {
  assert.equal(formatTimecode(0), '0:00.00')
  assert.equal(formatTimecode(61.5), '1:01.50')
  assert.equal(formatTimecode(-1), '0:00.00')
  assert.equal(formatTimecode(NaN), '0:00.00')
})
