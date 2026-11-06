import { describe, expect, it } from 'vitest'
import { encodeWav } from './wav'

async function bytesOf(blob: Blob): Promise<DataView> {
  return new DataView(await blob.arrayBuffer())
}

function ascii(view: DataView, offset: number, length: number): string {
  let text = ''
  for (let i = 0; i < length; i += 1) text += String.fromCharCode(view.getUint8(offset + i))
  return text
}

describe('encodeWav', () => {
  it('writes a 16 kHz mono 16-bit PCM header', async () => {
    const blob = encodeWav(new Float32Array([0, 0.5, -0.5]), 16_000)
    const view = await bytesOf(blob)
    expect(blob.type).toBe('audio/wav')
    expect(view.byteLength).toBe(44 + 6)
    expect(ascii(view, 0, 4)).toBe('RIFF')
    expect(view.getUint32(4, true)).toBe(36 + 6)
    expect(ascii(view, 8, 4)).toBe('WAVE')
    expect(ascii(view, 12, 4)).toBe('fmt ')
    expect(view.getUint32(16, true)).toBe(16)
    expect(view.getUint16(20, true)).toBe(1)
    expect(view.getUint16(22, true)).toBe(1)
    expect(view.getUint32(24, true)).toBe(16_000)
    expect(view.getUint32(28, true)).toBe(32_000)
    expect(view.getUint16(32, true)).toBe(2)
    expect(view.getUint16(34, true)).toBe(16)
    expect(ascii(view, 36, 4)).toBe('data')
    expect(view.getUint32(40, true)).toBe(6)
  })

  it('keeps samples little-endian and in order', async () => {
    const view = await bytesOf(encodeWav(new Float32Array([0, 0.5, -0.5]), 16_000))
    expect(view.getInt16(44, true)).toBe(0)
    expect(view.getInt16(46, true)).toBe(16383)
    expect(view.getInt16(48, true)).toBe(-16384)
  })

  it('clamps what resampling overshoots', async () => {
    const view = await bytesOf(encodeWav(new Float32Array([1.0099, -2, 1, -1]), 16_000))
    expect(view.getInt16(44, true)).toBe(32767)
    expect(view.getInt16(46, true)).toBe(-32768)
    expect(view.getInt16(48, true)).toBe(32767)
    expect(view.getInt16(50, true)).toBe(-32768)
  })

  it('still gives a valid file for no samples', async () => {
    const view = await bytesOf(encodeWav(new Float32Array(0), 16_000))
    expect(view.byteLength).toBe(44)
    expect(view.getUint32(4, true)).toBe(36)
    expect(view.getUint32(40, true)).toBe(0)
  })
})
