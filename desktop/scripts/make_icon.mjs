// Draws FrameGrab's icon straight to PNG — no design tool, no image library.
//
// It is deliberately simple: a dark rounded square (the app's canvas colour)
// with sprocket holes down both edges and a green play triangle, which reads
// at 32px as well as at 1024px. Run it with `npm run icon`; pass a size to get
// a single file, or nothing to write the whole set.
import { deflateSync } from 'node:zlib'
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ICONS = join(HERE, '..', 'src-tauri', 'icons')

const BACKGROUND = [18, 18, 20]
const PANEL = [27, 27, 31]
const ACCENT = [46, 204, 112]

/** Signed distance to a rounded rectangle, used for anti-aliased edges. */
function roundedRectDistance(x, y, halfW, halfH, radius) {
  const dx = Math.abs(x) - (halfW - radius)
  const dy = Math.abs(y) - (halfH - radius)
  const outside = Math.hypot(Math.max(dx, 0), Math.max(dy, 0))
  return outside + Math.min(Math.max(dx, dy), 0) - radius
}

/** How much of a pixel is covered, given a signed distance and a soft edge. */
function coverage(distance, feather) {
  return Math.min(1, Math.max(0, 0.5 - distance / feather))
}

function blend(base, layer, alpha) {
  return base.map((c, i) => Math.round(c + (layer[i] - c) * alpha))
}

function render(size) {
  const pixels = Buffer.alloc(size * size * 4)
  const s = size / 1024 // everything below is authored at 1024
  const feather = Math.max(1, 1.5 * s)

  // Play triangle, pointing right. Nudged past centre because a triangle's
  // optical centre sits behind its tip.
  const triHalfHeight = 210 * s
  const triWidth = 330 * s
  const triLeft = -triWidth / 2 + 24 * s

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const px = x + 0.5 - size / 2
      const py = y + 0.5 - size / 2

      const inCard = coverage(roundedRectDistance(px, py, size / 2, size / 2, 224 * s), feather)
      let colour = BACKGROUND

      // Sprocket holes down the left and right edges, like a film strip.
      const holeSpacing = 150 * s
      const holeRadius = 34 * s
      const nearestHoleY = Math.round(py / holeSpacing) * holeSpacing
      for (const holeX of [-size / 2 + 92 * s, size / 2 - 92 * s]) {
        const d = roundedRectDistance(px - holeX, py - nearestHoleY, holeRadius, holeRadius, holeRadius * 0.45)
        colour = blend(colour, PANEL, coverage(d, feather))
      }

      // The triangle tapers to a point as it crosses from left edge to tip.
      const progress = (px - triLeft) / triWidth
      if (progress >= 0 && progress <= 1) {
        // Soften the two long edges so the point doesn't look ragged.
        const edge = Math.abs(py) - triHalfHeight * (1 - progress)
        colour = blend(colour, ACCENT, coverage(edge, feather * 2))
      }

      const offset = (y * size + x) * 4
      pixels[offset] = colour[0]
      pixels[offset + 1] = colour[1]
      pixels[offset + 2] = colour[2]
      pixels[offset + 3] = Math.round(inCard * 255)
    }
  }
  return encodePng(size, size, pixels)
}

function encodePng(width, height, rgba) {
  // One filter byte (0 = None) in front of every row, as PNG requires.
  const raw = Buffer.alloc((width * 4 + 1) * height)
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4)
  }

  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // colour type: RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

function chunk(type, data) {
  const head = Buffer.alloc(8)
  head.writeUInt32BE(data.length, 0)
  head.write(type, 4, 'ascii')
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0)
  return Buffer.concat([head, data, crc])
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})

function crc32(buffer) {
  let c = 0xffffffff
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

mkdirSync(ICONS, { recursive: true })
const requested = process.argv[2] ? [Number(process.argv[2])] : [32, 128, 256, 512, 1024]
for (const size of requested) {
  const name = size === 1024 ? 'icon.png' : `${size}x${size}.png`
  writeFileSync(join(ICONS, name), render(size))
  console.log(`icons/${name}`)
}
