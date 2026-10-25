/**
 * Geometry of the 24-hour clock face (mobile time picker). Maps between an
 * hour or minute and a point on the dial; knows nothing about dates, zones or
 * DST. Ported from the P8-b5.6b-1 prototype.
 *
 * Hours use two rings, as Material's 24-hour clock does:
 *   outer ring  12 (top), 1 .. 11
 *   inner ring  00 (top), 13 .. 23
 */

export const SIZE = 256;
export const C = SIZE / 2;
export const R_OUTER = 102;
export const R_INNER = 66;
const RING_SPLIT = (R_OUTER + R_INNER) / 2;

export interface DialPos {
  /** 0 = top, clockwise, in degrees */
  deg: number;
  r: number;
}

export function hourPos(h: number): DialPos {
  if (h === 0) return { deg: 0, r: R_INNER };
  if (h === 12) return { deg: 0, r: R_OUTER };
  if (h < 12) return { deg: h * 30, r: R_OUTER };
  return { deg: (h - 12) * 30, r: R_INNER };
}

export function minutePos(m: number): DialPos {
  return { deg: m * 6, r: R_OUTER };
}

export function xy(p: DialPos): { x: number; y: number } {
  const rad = (p.deg * Math.PI) / 180;
  return { x: C + p.r * Math.sin(rad), y: C - p.r * Math.cos(rad) };
}

/** Point in dial coordinates -> angle (0..360, 0 = top) and distance from centre. */
function polar(x: number, y: number): { deg: number; dist: number } {
  const dx = x - C;
  const dy = y - C;
  let deg = (Math.atan2(dx, -dy) * 180) / Math.PI;
  if (deg < 0) deg += 360;
  return { deg, dist: Math.hypot(dx, dy) };
}

export function hourAt(x: number, y: number): number {
  const { deg, dist } = polar(x, y);
  const i = Math.round(deg / 30) % 12;
  const inner = dist < RING_SPLIT;
  if (inner) return i === 0 ? 0 : i + 12;
  return i === 0 ? 12 : i;
}

export function minuteAt(x: number, y: number): number {
  return Math.round(polar(x, y).deg / 6) % 60;
}

export const HOURS_OUTER = [12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
export const HOURS_INNER = [0, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23];
export const MINUTE_LABELS = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55];

/** Rotate `prev` to the equivalent of `next` (mod 360) nearest to it, so the hand never spins the long way. */
export function nearestTurn(prev: number, next: number): number {
  const delta = ((((next - prev) % 360) + 540) % 360) - 180;
  return prev + delta;
}

export const pad2 = (n: number) => String(n).padStart(2, '0');
