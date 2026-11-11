import { TouchControlMode } from '@/jotai/mouse.ts';
import { ViewportZoomState } from '@/jotai/screen.ts';

export enum TouchMouseButton {
  Left = 0,
  Middle = 1,
  Right = 2
}

export interface TouchGestureOptions {
  getTouchMode: () => TouchControlMode;
  getScrollConfig: () => { direction: number; interval: number };
  getZoom: () => ViewportZoomState;
  setZoom: (next: ViewportZoomState) => void;
  onDirectMove?: (clientX: number, clientY: number) => boolean;
  onRelativeMove: (dxCss: number, dyCss: number) => boolean;
  onButton: (type: 'mousedown' | 'mouseup', button: number) => boolean;
  onWheel: (deltaY: number, deltaX: number, clientX: number, clientY: number) => void;
  onResetButtons: () => void;
}

const TAP_MAX_DIST = 10;
const TAP_MAX_MS = 260;
const DOUBLE_TAP_WINDOW_MS = 300;
const DOUBLE_TAP_MAX_DIST = 32;
const DIRECT_DRAG_THRESHOLD = 10;
const LONG_PRESS_MS = 600;
const PINCH_LOCK_PX = 14;
const SCROLL_LOCK_PX = 10;
const PAN_START_PX = 3;
const SCROLL_STEP_PX = 22;

export function createTouchGestureController(options: TouchGestureOptions) {
  let activeTouchCount = 0;
  let sequenceCanceled = false;

  // Single-finger state
  let startTime = 0;
  let startX = 0;
  let startY = 0;
  let prevX = 0;
  let prevY = 0;
  let prevMoveTime = 0;
  let maxMoveDist = 0;
  let isDragging = false;
  let isDoubleTapCandidate = false;
  let isLongPress = false;
  let pressedButton: TouchMouseButton | null = null;

  let longPressTimer: ReturnType<typeof setTimeout> | null = null;
  let doubleTapHoldTimer: ReturnType<typeof setTimeout> | null = null;
  const pendingTapReleases = new Map<ReturnType<typeof setTimeout>, TouchMouseButton>();

  let lastTapTime = 0;
  let lastTapX = 0;
  let lastTapY = 0;
  let lastScrollTime = 0;

  // Multi-touch state
  let isMultiTouch = false;
  let twoFingerStartTime = 0;
  let startPinchDist = 0;
  let prevPinchDist = 0;
  let startMidX = 0;
  let startMidY = 0;
  let prevMidX = 0;
  let prevMidY = 0;
  let maxPinchDelta = 0;
  let maxMidDelta = 0;
  let multiMode: 'undecided' | 'pinch' | 'scroll' = 'undecided';
  let pinchScaleUnlocked = false;
  let scrollAccX = 0;
  let scrollAccY = 0;

  function clearSingleFingerTimers() {
    if (longPressTimer) {
      clearTimeout(longPressTimer);
      longPressTimer = null;
    }
    if (doubleTapHoldTimer) {
      clearTimeout(doubleTapHoldTimer);
      doubleTapHoldTimer = null;
    }
  }

  function clearAllTimers() {
    clearSingleFingerTimers();
    for (const timer of pendingTapReleases.keys()) {
      clearTimeout(timer);
    }
    pendingTapReleases.clear();
  }

  function flushPendingTapReleases() {
    if (pendingTapReleases.size === 0) return;
    for (const [timer, button] of pendingTapReleases) {
      clearTimeout(timer);
      options.onButton('mouseup', button);
    }
    pendingTapReleases.clear();
  }

  function emitQuickClick(button: TouchMouseButton) {
    const sent = options.onButton('mousedown', button);
    if (!sent) return;
    const timer = setTimeout(() => {
      pendingTapReleases.delete(timer);
      options.onButton('mouseup', button);
    }, 45);
    pendingTapReleases.set(timer, button);
  }

  function cancel(cancelActiveSequence = true) {
    clearAllTimers();

    if (cancelActiveSequence && activeTouchCount > 0) {
      sequenceCanceled = true;
    }

    isDragging = false;
    isDoubleTapCandidate = false;
    isLongPress = false;
    pressedButton = null;
    isMultiTouch = false;
    multiMode = 'undecided';
    pinchScaleUnlocked = false;
    scrollAccX = 0;
    scrollAccY = 0;
  }

  function getTwoFingerMetrics(t0: Touch, t1: Touch) {
    const dx = t1.clientX - t0.clientX;
    const dy = t1.clientY - t0.clientY;
    return {
      dist: Math.hypot(dx, dy),
      midX: (t0.clientX + t1.clientX) / 2,
      midY: (t0.clientY + t1.clientY) / 2
    };
  }

  function clampZoom(scale: number, x: number, y: number, surface: HTMLElement): ViewportZoomState {
    if (scale <= 1.02) {
      return { scale: 1, x: 0, y: 0 };
    }
    const clampedScale = Math.min(5, Math.max(1, scale));
    const rect = surface.getBoundingClientRect();
    const maxPanX = (rect.width * (clampedScale - 1)) / 2;
    const maxPanY = (rect.height * (clampedScale - 1)) / 2;

    return {
      scale: clampedScale,
      x: Math.max(-maxPanX, Math.min(maxPanX, x)),
      y: Math.max(-maxPanY, Math.min(maxPanY, y))
    };
  }

  function attach(surface: HTMLElement): () => void {
    function handleTouchStart(e: TouchEvent) {
      e.preventDefault();
      e.stopPropagation();

      if (e.touches.length === 0) return;

      const startsNewSequence = e.touches.length === e.changedTouches.length;
      if (startsNewSequence) {
        clearSingleFingerTimers();
        flushPendingTapReleases();
        if (pressedButton !== null) {
          options.onResetButtons();
          pressedButton = null;
        }
        sequenceCanceled = false;
        isMultiTouch = false;
      }

      activeTouchCount = e.touches.length;
      if (sequenceCanceled) return;

      if (e.touches.length >= 2) {
        clearSingleFingerTimers();
        if (pressedButton !== null) {
          options.onButton('mouseup', pressedButton);
          pressedButton = null;
        }
        isDragging = false;
        isDoubleTapCandidate = false;
        isLongPress = false;

        if (!isMultiTouch) {
          isMultiTouch = true;
          twoFingerStartTime = Date.now();
          const m = getTwoFingerMetrics(e.touches[0], e.touches[1]);
          startPinchDist = m.dist;
          prevPinchDist = m.dist;
          startMidX = m.midX;
          startMidY = m.midY;
          prevMidX = m.midX;
          prevMidY = m.midY;
          maxPinchDelta = 0;
          maxMidDelta = 0;
          multiMode = 'undecided';
          pinchScaleUnlocked = false;
          scrollAccX = 0;
          scrollAccY = 0;
        }
        return;
      }

      const touch = e.touches[0];
      const now = Date.now();
      const mode = options.onDirectMove ? options.getTouchMode() : 'trackpad';

      startTime = now;
      startX = touch.clientX;
      startY = touch.clientY;
      prevX = touch.clientX;
      prevY = touch.clientY;
      prevMoveTime = now;
      maxMoveDist = 0;
      isDragging = false;
      isLongPress = false;
      pressedButton = null;

      clearSingleFingerTimers();

      if (mode === 'direct' && options.onDirectMove) {
        isDoubleTapCandidate = false;
        if (!options.onDirectMove(touch.clientX, touch.clientY)) {
          sequenceCanceled = true;
          return;
        }
      } else {
        // Trackpad mode: check if this is the 2nd tap of a double-tap-and-drag
        const sinceLastTap = now - lastTapTime;
        const distFromLastTap = Math.hypot(touch.clientX - lastTapX, touch.clientY - lastTapY);
        isDoubleTapCandidate =
          sinceLastTap <= DOUBLE_TAP_WINDOW_MS && distFromLastTap <= DOUBLE_TAP_MAX_DIST;

        if (isDoubleTapCandidate) {
          doubleTapHoldTimer = setTimeout(() => {
            doubleTapHoldTimer = null;
            if (!isDragging && !isMultiTouch && pressedButton === null) {
              isDragging = true;
              pressedButton = TouchMouseButton.Left;
              options.onButton('mousedown', TouchMouseButton.Left);
            }
          }, 150);
        }
      }

      if (!isDoubleTapCandidate) {
        longPressTimer = setTimeout(() => {
          longPressTimer = null;
          if (isDragging || isMultiTouch) return;
          isLongPress = true;
          pressedButton = TouchMouseButton.Right;
          if (navigator.vibrate) {
            navigator.vibrate(40);
          }
          options.onButton('mousedown', TouchMouseButton.Right);
        }, LONG_PRESS_MS);
      }
    }

    function handleTouchMove(e: TouchEvent) {
      e.preventDefault();
      e.stopPropagation();

      activeTouchCount = e.touches.length;
      if (sequenceCanceled || e.touches.length === 0) return;

      if (isMultiTouch) {
        if (e.touches.length < 2) return;

        const m = getTwoFingerMetrics(e.touches[0], e.touches[1]);
        const distDelta = Math.abs(m.dist - startPinchDist);
        const midDelta = Math.hypot(m.midX - startMidX, m.midY - startMidY);
        maxPinchDelta = Math.max(maxPinchDelta, distDelta);
        maxMidDelta = Math.max(maxMidDelta, midDelta);

        if (distDelta > PINCH_LOCK_PX) {
          pinchScaleUnlocked = true;
        }

        if (multiMode === 'undecided') {
          const isCurrentlyZoomed = options.getZoom().scale > 1.02;
          if (pinchScaleUnlocked) {
            multiMode = 'pinch';
          } else if (isCurrentlyZoomed && midDelta > PAN_START_PX) {
            // When zoomed in, 2-finger swipe immediately pans the zoomed viewport
            multiMode = 'pinch';
          } else if (!isCurrentlyZoomed && midDelta > SCROLL_LOCK_PX) {
            multiMode = 'scroll';
          }
        } else if (multiMode === 'scroll' && distDelta > PINCH_LOCK_PX * 1.5) {
          // Allow transitioning into pinch-zoom if fingers spread apart mid-gesture
          pinchScaleUnlocked = true;
          multiMode = 'pinch';
        }

        if (multiMode === 'pinch' && prevPinchDist > 0) {
          const currentZoom = options.getZoom();
          const ratio = pinchScaleUnlocked ? m.dist / prevPinchDist : 1;
          const nextScale = Math.min(5, Math.max(1, currentZoom.scale * ratio));
          const rect = surface.getBoundingClientRect();
          const cx = rect.left + rect.width / 2;
          const cy = rect.top + rect.height / 2;
          const effectiveRatio = nextScale / currentZoom.scale;

          const nextX = m.midX - cx - (prevMidX - cx - currentZoom.x) * effectiveRatio;
          const nextY = m.midY - cy - (prevMidY - cy - currentZoom.y) * effectiveRatio;

          options.setZoom(clampZoom(nextScale, nextX, nextY, surface));
        } else if (multiMode === 'scroll') {
          const { direction, interval } = options.getScrollConfig();
          scrollAccY += m.midY - prevMidY;
          scrollAccX += m.midX - prevMidX;

          const now = Date.now();
          if (
            (Math.abs(scrollAccY) >= SCROLL_STEP_PX || Math.abs(scrollAccX) >= SCROLL_STEP_PX) &&
            now - lastScrollTime >= interval
          ) {
            const ticksY = Math.trunc(scrollAccY / SCROLL_STEP_PX);
            const ticksX = Math.trunc(scrollAccX / SCROLL_STEP_PX);
            scrollAccY -= ticksY * SCROLL_STEP_PX;
            scrollAccX -= ticksX * SCROLL_STEP_PX;

            // Finger moving down scrolls content up (natural trackpad scrolling) modulated by scrollDirection
            const deltaY = ticksY !== 0 ? (ticksY > 0 ? -1 : 1) * direction : 0;
            const deltaX = ticksX !== 0 ? (ticksX > 0 ? 1 : -1) * direction : 0;

            if (deltaY !== 0 || deltaX !== 0) {
              options.onWheel(deltaY, deltaX, m.midX, m.midY);
              lastScrollTime = now;
            }
          }
        }

        prevPinchDist = m.dist;
        prevMidX = m.midX;
        prevMidY = m.midY;
        return;
      }

      const touch = e.touches[0];
      const now = Date.now();
      const mode = options.onDirectMove ? options.getTouchMode() : 'trackpad';

      const totalDist = Math.hypot(touch.clientX - startX, touch.clientY - startY);
      maxMoveDist = Math.max(maxMoveDist, totalDist);

      if (totalDist > TAP_MAX_DIST && longPressTimer) {
        clearTimeout(longPressTimer);
        longPressTimer = null;
      }

      if (mode === 'direct' && options.onDirectMove) {
        if (totalDist > DIRECT_DRAG_THRESHOLD && !isDragging && !isLongPress) {
          isDragging = true;
          pressedButton = TouchMouseButton.Left;
          options.onButton('mousedown', TouchMouseButton.Left);
        }

        if (isDragging || isLongPress) {
          options.onDirectMove(touch.clientX, touch.clientY);
        }
        prevX = touch.clientX;
        prevY = touch.clientY;
        prevMoveTime = now;
        return;
      }

      // Trackpad mode
      const dx = touch.clientX - prevX;
      const dy = touch.clientY - prevY;
      const dt = Math.max(8, now - prevMoveTime);

      if (isDoubleTapCandidate && totalDist > 5 && !isDragging && pressedButton === null) {
        if (doubleTapHoldTimer) {
          clearTimeout(doubleTapHoldTimer);
          doubleTapHoldTimer = null;
        }
        isDragging = true;
        pressedButton = TouchMouseButton.Left;
        options.onButton('mousedown', TouchMouseButton.Left);
      }

      if (dx !== 0 || dy !== 0) {
        const velocity = Math.hypot(dx, dy) / dt; // px per ms
        const accel = Math.min(2.6, Math.max(1.0, 0.9 + velocity * 0.85));
        options.onRelativeMove(dx * accel, dy * accel);
      }

      prevX = touch.clientX;
      prevY = touch.clientY;
      prevMoveTime = now;
    }

    function handleTouchEnd(e: TouchEvent) {
      e.preventDefault();
      e.stopPropagation();

      activeTouchCount = e.touches.length;
      clearSingleFingerTimers();

      if (sequenceCanceled) {
        if (e.touches.length === 0) {
          sequenceCanceled = false;
        }
        return;
      }

      if (isMultiTouch) {
        if (e.touches.length === 0) {
          const duration = Date.now() - twoFingerStartTime;
          if (
            multiMode === 'undecided' &&
            duration <= 280 &&
            maxMidDelta <= 14 &&
            maxPinchDelta <= PINCH_LOCK_PX
          ) {
            emitQuickClick(TouchMouseButton.Right);
          }
          isMultiTouch = false;
          multiMode = 'undecided';
        }
        return;
      }

      const now = Date.now();
      const duration = now - startTime;

      if (!isDragging && !isLongPress && maxMoveDist <= TAP_MAX_DIST && duration <= TAP_MAX_MS) {
        emitQuickClick(TouchMouseButton.Left);
        if (isDoubleTapCandidate) {
          lastTapTime = 0;
        } else {
          lastTapTime = now;
          lastTapX = startX;
          lastTapY = startY;
        }
      } else if (pressedButton !== null) {
        options.onButton('mouseup', pressedButton);
      }

      isDragging = false;
      isDoubleTapCandidate = false;
      isLongPress = false;
      pressedButton = null;
    }

    function handleTouchCancel(e: TouchEvent) {
      e.preventDefault();
      e.stopPropagation();

      activeTouchCount = e.touches.length;
      cancel(true);
      options.onResetButtons();

      if (e.touches.length === 0) {
        sequenceCanceled = false;
      }
    }

    surface.addEventListener('touchstart', handleTouchStart, { passive: false });
    surface.addEventListener('touchmove', handleTouchMove, { passive: false });
    surface.addEventListener('touchend', handleTouchEnd, { passive: false });
    surface.addEventListener('touchcancel', handleTouchCancel, { passive: false });

    return () => {
      surface.removeEventListener('touchstart', handleTouchStart);
      surface.removeEventListener('touchmove', handleTouchMove);
      surface.removeEventListener('touchend', handleTouchEnd);
      surface.removeEventListener('touchcancel', handleTouchCancel);
    };
  }

  return {
    attach,
    cancel
  };
}
