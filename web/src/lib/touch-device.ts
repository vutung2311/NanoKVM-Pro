export function detectTouchDevice(): boolean {
  if (typeof window === 'undefined') {
    return false;
  }

  if (window.matchMedia('(pointer: coarse)').matches) {
    return true;
  }

  // Fallback for mobile WebViews that omit pointer media queries
  const hasFinePointer = window.matchMedia('(pointer: fine)').matches;
  return !hasFinePointer && ('ontouchstart' in window || navigator.maxTouchPoints > 0);
}

// True when the device has any touch input, including touchscreen laptops whose primary
// pointer is a mouse/trackpad (useTouchDevice() is false there). Touch handlers are attached
// on every device, so touch settings must be reachable whenever this is true.
export function hasTouchInput(): boolean {
  if (typeof window === 'undefined') {
    return false;
  }
  return navigator.maxTouchPoints > 0 || 'ontouchstart' in window;
}

// Phones/tablets (coarse primary pointer) default to the virtual trackpad; everything else
// defaults to upstream's direct touch, so a touchscreen laptop keeps tap-to-click.
export function defaultTouchMode(): 'trackpad' | 'direct' {
  return detectTouchDevice() ? 'trackpad' : 'direct';
}
