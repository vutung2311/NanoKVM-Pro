// Map a desktop WheelEvent onto one HID wheel tick on a single axis.
//
// Only the dominant axis is sent: trackpads report a little sideways motion with almost every
// vertical swipe, and sending a full horizontal tick for that makes the host scroll sideways.
// Pixel-mode deltas below 1 px (trackpad jitter, the tail of an inertial fling) are ignored
// instead of being rounded up to a full tick. Line/page-mode deltas are always whole notches.
export function getWheelTicks(
  e: WheelEvent,
  direction: number
): { deltaY: number; deltaX: number } | null {
  const absY = Math.abs(e.deltaY);
  const absX = Math.abs(e.deltaX);
  const minDelta = e.deltaMode === WheelEvent.DOM_DELTA_PIXEL ? 1 : Number.MIN_VALUE;

  if (absY >= absX) {
    if (absY < minDelta) return null;
    return { deltaY: (e.deltaY > 0 ? 1 : -1) * direction, deltaX: 0 };
  }

  if (absX < minDelta) return null;
  return { deltaY: 0, deltaX: (e.deltaX > 0 ? -1 : 1) * direction };
}
