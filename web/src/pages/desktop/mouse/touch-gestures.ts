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
  onZoomScrollStateChange?: (active: boolean) => void;
}

const TAP_MAX_DIST = 10;
const TAP_MAX_MS = 260;
const DOUBLE_TAP_WINDOW_MS = 300;
const DOUBLE_TAP_MAX_DIST = 32;
const DIRECT_DRAG_THRESHOLD = 10;
const LONG_PRESS_MS = 600;
const PINCH_LOCK_PX = 14;
const SCROLL_LOCK_PX = 10;
const ZOOMED_PAN_LOCK_PX = 10;
const TWO_FINGER_SCROLL_HOLD_MS = 180;
const SCROLL_STEP_PX = 20;
const MAX_WHEEL_TICKS_PER_STEP = 6;
const MIN_MOMENTUM_VELOCITY = 0.45;
const MAX_MOMENTUM_VELOCITY = 3.6;

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
  let twoFingerHoldTimer: ReturnType<typeof setTimeout> | null = null;
  const pendingTapReleases = new Map<ReturnType<typeof setTimeout>, TouchMouseButton>();

  let lastTapTime = 0;
  let lastTapX = 0;
  let lastTapY = 0;
  let lastScrollTime = 0;

  // Multi-touch state
  let isMultiTouch = false;
  let maxTouchCount = 0;
  let twoFingerStartTime = 0;
  let startPinchDist = 0;
  let prevPinchDist = 0;
  let startMidX = 0;
  let startMidY = 0;
  let prevMidX = 0;
  let prevMidY = 0;
  let scrollAnchorX = 0;
  let scrollAnchorY = 0;
  let maxPinchDelta = 0;
  let maxMidDelta = 0;
  let multiMode: 'undecided' | 'pinch' | 'scroll' = 'undecided';
  // Identifiers of the two surface touches the current baselines were measured from.
  let pairIds: [number, number] | null = null;
  // A two-finger tap (right click) only counts if two fingers went down once and nothing else happened.
  let twoFingerTapEligible = false;
  let pinchScaleUnlocked = false;
  let scrollLockedByHold = false;
  let zoomScrollBadgeActive = false;
  let scrollAccX = 0;
  let scrollAccY = 0;
  let prevMultiMoveTime = 0;
  let lastMultiMoveTime = 0;
  let scrollVelX = 0;
  let scrollVelY = 0;
  let momentumStartedThisGesture = false;
  let stoppedCoastingOnTouchStart = false;
  let scrollMomentumRaf: number | null = null;

  function stopScrollMomentum() {
    if (scrollMomentumRaf !== null) {
      cancelAnimationFrame(scrollMomentumRaf);
      scrollMomentumRaf = null;
    }
    scrollVelX = 0;
    scrollVelY = 0;
  }

  function startScrollMomentum(vx: number, vy: number, anchorX: number, anchorY: number) {
    stopScrollMomentum();
    const speed = Math.hypot(vx, vy);
    if (speed < MIN_MOMENTUM_VELOCITY) return;

    const scale = Math.min(MAX_MOMENTUM_VELOCITY, speed * 1.3) / speed;
    let curVx = vx * scale;
    let curVy = vy * scale;
    let lastFrame = performance.now();

    const step = (frameNow: number) => {
      const dt = Math.min(34, Math.max(8, frameNow - lastFrame));
      lastFrame = frameNow;

      const friction = Math.pow(0.92, dt / 16);
      curVx *= friction;
      curVy *= friction;

      if (Math.hypot(curVx, curVy) < 0.08) {
        scrollMomentumRaf = null;
        return;
      }

      emitAccumulatedScroll(curVx * dt, curVy * dt, anchorX, anchorY);
      scrollMomentumRaf = requestAnimationFrame(step);
    };

    scrollMomentumRaf = requestAnimationFrame(step);
  }

  function setZoomScrollActive(active: boolean) {
    if (zoomScrollBadgeActive === active) return;
    zoomScrollBadgeActive = active;
    options.onZoomScrollStateChange?.(active);
  }

  function clearTwoFingerHoldTimer() {
    if (twoFingerHoldTimer) {
      clearTimeout(twoFingerHoldTimer);
      twoFingerHoldTimer = null;
    }
  }

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
    clearTwoFingerHoldTimer();
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
    stopScrollMomentum();
    setZoomScrollActive(false);

    if (cancelActiveSequence && activeTouchCount > 0) {
      sequenceCanceled = true;
    }

    isDragging = false;
    isDoubleTapCandidate = false;
    isLongPress = false;
    pressedButton = null;
    isMultiTouch = false;
    maxTouchCount = 0;
    multiMode = 'undecided';
    pairIds = null;
    twoFingerTapEligible = false;
    pinchScaleUnlocked = false;
    scrollLockedByHold = false;
    momentumStartedThisGesture = false;
    stoppedCoastingOnTouchStart = false;
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

  /**
   * (Re)measure every two-finger baseline from the given pair. Called whenever the surface
   * touch count becomes 2 (first contact, 1→2 after lifting a finger, 3→2) so a stale
   * distance/midpoint never turns into a zoom jump or a burst of wheel ticks.
   */
  function seedTwoFinger(t0: Touch, t1: Touch, firstEntry: boolean) {
    const now = Date.now();
    stopScrollMomentum();
    clearTwoFingerHoldTimer();
    setZoomScrollActive(false);

    pairIds = [t0.identifier, t1.identifier];
    const m = getTwoFingerMetrics(t0, t1);
    startPinchDist = m.dist;
    prevPinchDist = m.dist;
    startMidX = m.midX;
    startMidY = m.midY;
    prevMidX = m.midX;
    prevMidY = m.midY;
    scrollAnchorX = m.midX;
    scrollAnchorY = m.midY;
    multiMode = 'undecided';
    pinchScaleUnlocked = false;
    scrollLockedByHold = false;
    momentumStartedThisGesture = false;
    prevMultiMoveTime = now;
    lastMultiMoveTime = 0;
    scrollVelX = 0;
    scrollVelY = 0;
    scrollAccX = 0;
    scrollAccY = 0;

    if (firstEntry) {
      twoFingerStartTime = now;
      maxPinchDelta = 0;
      maxMidDelta = 0;
      twoFingerTapEligible = true;
    } else {
      twoFingerTapEligible = false;
    }

    if (options.getZoom().scale > 1.02) {
      twoFingerHoldTimer = setTimeout(() => {
        twoFingerHoldTimer = null;
        if (!isMultiTouch || activeTouchCount !== 2 || multiMode !== 'undecided') {
          return;
        }
        multiMode = 'scroll';
        scrollLockedByHold = true;
        prevMultiMoveTime = Date.now();
        lastMultiMoveTime = 0;
        scrollVelX = 0;
        scrollVelY = 0;
        scrollAccX = 0;
        scrollAccY = 0;
        if (navigator.vibrate) {
          navigator.vibrate(25);
        }
        setZoomScrollActive(true);
      }, TWO_FINGER_SCROLL_HOLD_MS);
    }
  }

  function emitAccumulatedScroll(
    stepDx: number,
    stepDy: number,
    anchorX: number,
    anchorY: number
  ) {
    const { direction, interval } = options.getScrollConfig();

    // Dampen cross-axis wrist drift during predominantly vertical or horizontal swipes
    if (Math.abs(stepDy) >= Math.abs(stepDx) * 1.5) {
      scrollAccY += stepDy;
      scrollAccX *= 0.5;
    } else if (Math.abs(stepDx) >= Math.abs(stepDy) * 1.5) {
      scrollAccX += stepDx;
      scrollAccY *= 0.5;
    } else {
      scrollAccY += stepDy;
      scrollAccX += stepDx;
    }

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
      const clampedTicksY = Math.max(-MAX_WHEEL_TICKS_PER_STEP, Math.min(MAX_WHEEL_TICKS_PER_STEP, -ticksY));
      const clampedTicksX = Math.max(-MAX_WHEEL_TICKS_PER_STEP, Math.min(MAX_WHEEL_TICKS_PER_STEP, ticksX));
      const deltaY = clampedTicksY !== 0 ? clampedTicksY * direction : 0;
      const deltaX = clampedTicksX !== 0 ? clampedTicksX * direction : 0;

      if (deltaY !== 0 || deltaX !== 0) {
        options.onWheel(deltaY, deltaX, anchorX, anchorY);
        lastScrollTime = now;
      }
    }
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
    // Only fingers that started on the gesture surface count. TouchEvent.touches also holds
    // fingers resting elsewhere (e.g. holding the on-screen L/M/R button), which must not
    // turn a one-finger drag into a pinch/scroll.
    function surfaceTouches(list: TouchList): Touch[] {
      const result: Touch[] = [];
      for (let i = 0; i < list.length; i++) {
        const t = list[i];
        if (t.target instanceof Node && surface.contains(t.target)) {
          result.push(t);
        }
      }
      return result;
    }

    function findPair(touches: Touch[]): [Touch, Touch] | null {
      if (!pairIds || touches.length !== 2) return null;
      const [idA, idB] = pairIds;
      const a = touches.find((t) => t.identifier === idA);
      const b = touches.find((t) => t.identifier === idB);
      return a && b ? [a, b] : null;
    }

    function handleTouchStart(e: TouchEvent) {
      e.preventDefault();
      e.stopPropagation();

      const touches = surfaceTouches(e.touches);
      if (touches.length === 0) return;

      const startsNewSequence = touches.length === surfaceTouches(e.changedTouches).length;
      if (startsNewSequence) {
        stoppedCoastingOnTouchStart = scrollMomentumRaf !== null;
        stopScrollMomentum();
        clearSingleFingerTimers();
        clearTwoFingerHoldTimer();
        setZoomScrollActive(false);
        flushPendingTapReleases();
        if (pressedButton !== null) {
          options.onResetButtons();
          pressedButton = null;
        }
        sequenceCanceled = false;
        isMultiTouch = false;
        maxTouchCount = 0;
        pairIds = null;
        twoFingerTapEligible = false;
        scrollLockedByHold = false;
        momentumStartedThisGesture = false;
      }

      activeTouchCount = touches.length;
      maxTouchCount = Math.max(maxTouchCount, touches.length);
      if (sequenceCanceled) return;

      if (touches.length >= 3) {
        clearSingleFingerTimers();
        clearTwoFingerHoldTimer();
        setZoomScrollActive(false);
        pairIds = null;
        if (pressedButton !== null) {
          options.onButton('mouseup', pressedButton);
          pressedButton = null;
        }
        isDragging = false;
        isDoubleTapCandidate = false;
        isLongPress = false;
        isMultiTouch = true;
        return;
      }

      if (touches.length === 2) {
        clearSingleFingerTimers();
        if (pressedButton !== null) {
          options.onButton('mouseup', pressedButton);
          pressedButton = null;
        }
        isDragging = false;
        isDoubleTapCandidate = false;
        isLongPress = false;

        const firstEntry = !isMultiTouch;
        isMultiTouch = true;
        seedTwoFinger(touches[0], touches[1], firstEntry);
        return;
      }

      const touch = touches[0];
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

      const touches = surfaceTouches(e.touches);
      activeTouchCount = touches.length;
      if (sequenceCanceled || touches.length === 0) return;

      if (isMultiTouch) {
        if (touches.length !== 2) {
          clearTwoFingerHoldTimer();
          pairIds = null;
          if (touches.length < 2) {
            setZoomScrollActive(false);
          }
          return;
        }

        const pair = findPair(touches);
        if (!pair) {
          // The finger set changed since the baselines were taken: re-measure, emit nothing.
          seedTwoFinger(touches[0], touches[1], false);
          return;
        }

        const m = getTwoFingerMetrics(pair[0], pair[1]);
        const distDelta = Math.abs(m.dist - startPinchDist);
        const midDelta = Math.hypot(m.midX - startMidX, m.midY - startMidY);
        maxPinchDelta = Math.max(maxPinchDelta, distDelta);
        maxMidDelta = Math.max(maxMidDelta, midDelta);

        if (!scrollLockedByHold && distDelta > PINCH_LOCK_PX) {
          pinchScaleUnlocked = true;
        }

        if (multiMode === 'undecided') {
          const isCurrentlyZoomed = options.getZoom().scale > 1.02;
          if (pinchScaleUnlocked) {
            clearTwoFingerHoldTimer();
            multiMode = 'pinch';
          } else if (isCurrentlyZoomed && midDelta > ZOOMED_PAN_LOCK_PX) {
            // Immediate 2-finger swipe while zoomed pans the viewport
            clearTwoFingerHoldTimer();
            multiMode = 'pinch';
          } else if (!isCurrentlyZoomed && midDelta > SCROLL_LOCK_PX) {
            clearTwoFingerHoldTimer();
            multiMode = 'scroll';
          }
        } else if (
          multiMode === 'scroll' &&
          !scrollLockedByHold &&
          distDelta > PINCH_LOCK_PX * 1.5
        ) {
          // Unzoomed scroll transitioning into pinch-zoom if fingers spread apart mid-gesture
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
          const now = Date.now();
          const dt = Math.max(4, now - prevMultiMoveTime);
          const stepDx = m.midX - prevMidX;
          const stepDy = m.midY - prevMidY;
          const instVx = stepDx / dt;
          const instVy = stepDy / dt;
          scrollVelX = scrollVelX * 0.35 + instVx * 0.65;
          scrollVelY = scrollVelY * 0.35 + instVy * 0.65;
          prevMultiMoveTime = now;
          lastMultiMoveTime = now;

          const speed = Math.hypot(instVx, instVy);
          const accel = speed <= 0.35 ? 1 : Math.min(3.2, 1 + (speed - 0.35) * 1.1);

          emitAccumulatedScroll(
            stepDx * accel,
            stepDy * accel,
            scrollAnchorX,
            scrollAnchorY
          );
        }

        prevPinchDist = m.dist;
        prevMidX = m.midX;
        prevMidY = m.midY;
        return;
      }

      const touch = touches[0];
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

      const touches = surfaceTouches(e.touches);
      activeTouchCount = touches.length;
      clearSingleFingerTimers();

      if (sequenceCanceled) {
        if (touches.length === 0) {
          sequenceCanceled = false;
        }
        return;
      }

      if (isMultiTouch) {
        if (touches.length === 2) {
          // 3→2: continue with fresh baselines from the remaining pair.
          seedTwoFinger(touches[0], touches[1], false);
        } else if (touches.length < 2) {
          pairIds = null;
          clearTwoFingerHoldTimer();
          setZoomScrollActive(false);

          if (
            !momentumStartedThisGesture &&
            multiMode === 'scroll' &&
            lastMultiMoveTime > 0 &&
            Date.now() - lastMultiMoveTime <= 90
          ) {
            momentumStartedThisGesture = true;
            startScrollMomentum(scrollVelX, scrollVelY, scrollAnchorX, scrollAnchorY);
          }
        }

        if (touches.length === 0) {
          const duration = Date.now() - twoFingerStartTime;
          if (
            twoFingerTapEligible &&
            maxTouchCount === 2 &&
            multiMode === 'undecided' &&
            duration <= 280 &&
            maxMidDelta <= 14 &&
            maxPinchDelta <= PINCH_LOCK_PX
          ) {
            emitQuickClick(TouchMouseButton.Right);
          }
          isMultiTouch = false;
          maxTouchCount = 0;
          twoFingerTapEligible = false;
          scrollLockedByHold = false;
          momentumStartedThisGesture = false;
          stoppedCoastingOnTouchStart = false;
          multiMode = 'undecided';
        }
        return;
      }

      const now = Date.now();
      const duration = now - startTime;

      if (!isDragging && !isLongPress && maxMoveDist <= TAP_MAX_DIST && duration <= TAP_MAX_MS) {
        if (!stoppedCoastingOnTouchStart) {
          emitQuickClick(TouchMouseButton.Left);
          if (isDoubleTapCandidate) {
            lastTapTime = 0;
          } else {
            lastTapTime = now;
            lastTapX = startX;
            lastTapY = startY;
          }
        }
      } else if (pressedButton !== null) {
        options.onButton('mouseup', pressedButton);
      }

      isDragging = false;
      isDoubleTapCandidate = false;
      isLongPress = false;
      pressedButton = null;
      stoppedCoastingOnTouchStart = false;
    }

    function handleTouchCancel(e: TouchEvent) {
      e.preventDefault();
      e.stopPropagation();

      activeTouchCount = surfaceTouches(e.touches).length;
      cancel(true);
      options.onResetButtons();

      if (activeTouchCount === 0) {
        sequenceCanceled = false;
      }
    }

    surface.addEventListener('touchstart', handleTouchStart, { passive: false });
    surface.addEventListener('touchmove', handleTouchMove, { passive: false });
    surface.addEventListener('touchend', handleTouchEnd, { passive: false });
    surface.addEventListener('touchcancel', handleTouchCancel, { passive: false });

    return () => {
      stopScrollMomentum();
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
