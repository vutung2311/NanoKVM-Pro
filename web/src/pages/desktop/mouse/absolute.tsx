import { useEffect, useRef } from 'react';
import { useAtom, useAtomValue, useSetAtom } from 'jotai';

import { MouseReportAbsolute } from '@/lib/mouse.ts';
import {
  getRenderedMediaBox,
  getScreenElement,
  inverseRotateDelta,
  inverseRotatePoint
} from '@/lib/video-transform.ts';
import {
  scrollDirectionAtom,
  scrollIntervalAtom,
  touchModeAtom,
  virtualCursorAtom
} from '@/jotai/mouse.ts';
import { videoModeAtom, videoParametersAtom, viewportZoomAtom } from '@/jotai/screen.ts';

import {
  registerMouseButtonHandler,
  registerMouseReleaseHandler,
  sendMouseRelease,
  sendMouseReport
} from './lifecycle.ts';
import { createTouchGestureController } from './touch-gestures.ts';
import { MouseAbsoluteEvent } from './types.ts';

interface ReleaseMouseOptions {
  force?: boolean;
  cancelTouchSequence?: boolean;
}

export const Absolute = () => {
  const scrollDirection = useAtomValue(scrollDirectionAtom);
  const scrollInterval = useAtomValue(scrollIntervalAtom);
  const touchMode = useAtomValue(touchModeAtom);
  const videoMode = useAtomValue(videoModeAtom);
  const videoParameters = useAtomValue(videoParametersAtom);
  const [zoom, setZoom] = useAtom(viewportZoomAtom);
  const setVirtualCursor = useSetAtom(virtualCursorAtom);

  const mouseRef = useRef(new MouseReportAbsolute());
  // Absolute reports store HID coordinates (0..0x7fff), paired with normalized float coords for sub-pixel trackpad glides.
  const lastPosRef = useRef({ x: 0x4000, y: 0x4000 });
  const floatPosRef = useRef({ x: 0.5, y: 0.5 });
  const lastScrollTimeRef = useRef(0);

  const touchModeRef = useRef(touchMode);
  touchModeRef.current = touchMode;
  const scrollConfigRef = useRef({ direction: scrollDirection, interval: scrollInterval });
  scrollConfigRef.current = { direction: scrollDirection, interval: scrollInterval };
  const zoomRef = useRef(zoom);
  zoomRef.current = zoom;
  const rotationRef = useRef(videoParameters.rotation);
  rotationRef.current = videoParameters.rotation;

  useEffect(() => {
    const screenElement = getScreenElement();
    if (!screenElement) return;
    const screen = screenElement;
    const touchSurface = document.getElementById('screen-viewport') ?? (screen as HTMLElement);

    let pendingClientPos: { clientX: number; clientY: number } | null = null;
    let pendingTrackpadPos: { x: number; y: number } | null = null;
    let moveRafId: number | null = null;

    function syncNormalizedFromHex(hexX: number, hexY: number, showVirtualCursor = false) {
      const nx = Math.max(0, Math.min(1, hexX / 0x7fff));
      const ny = Math.max(0, Math.min(1, hexY / 0x7fff));
      floatPosRef.current = { x: nx, y: ny };
      setVirtualCursor((prev) => {
        if (!showVirtualCursor && !prev.visible) {
          return prev;
        }
        return { x: nx, y: ny, visible: showVirtualCursor };
      });
    }

    function flushMouseMove() {
      if (moveRafId !== null) {
        cancelAnimationFrame(moveRafId);
        moveRafId = null;
      }

      if (pendingTrackpadPos !== null) {
        const next = pendingTrackpadPos;
        pendingTrackpadPos = null;
        const hexX = Math.round(0x7fff * next.x);
        const hexY = Math.round(0x7fff * next.y);
        setVirtualCursor({ x: next.x, y: next.y, visible: true });
        if (hexX !== lastPosRef.current.x || hexY !== lastPosRef.current.y) {
          handleMouseEvent({ type: 'move', x: hexX, y: hexY });
        }
        return;
      }

      if (pendingClientPos !== null) {
        const pos = pendingClientPos;
        pendingClientPos = null;
        const coord = getCoordinate(pos);
        syncNormalizedFromHex(coord.x, coord.y, false);
        if (coord.x !== lastPosRef.current.x || coord.y !== lastPosRef.current.y) {
          handleMouseEvent({ type: 'move', x: coord.x, y: coord.y });
        }
      }
    }

    function handleMouseDown(e: MouseEvent) {
      disableEvent(e);
      flushMouseMove();
      const coord = getCoordinate(e);
      lastPosRef.current = coord;
      syncNormalizedFromHex(coord.x, coord.y, false);
      handleMouseEvent({ type: 'mousedown', button: e.button });
    }

    function handleMouseUp(e: MouseEvent) {
      disableEvent(e);
      flushMouseMove();
      const coord = getCoordinate(e);
      lastPosRef.current = coord;
      syncNormalizedFromHex(coord.x, coord.y, false);
      handleMouseEvent({ type: 'mouseup', button: e.button });
    }

    function handleMouseMove(e: MouseEvent) {
      disableEvent(e);
      pendingClientPos = { clientX: e.clientX, clientY: e.clientY };

      if (moveRafId === null) {
        moveRafId = requestAnimationFrame(flushMouseMove);
      }
    }

    function handleWindowMouseMove(e: MouseEvent) {
      if (mouseRef.current.hasPressedButtons) {
        handleMouseMove(e);
      }
    }

    function handleWheel(e: WheelEvent) {
      disableEvent(e);

      if (e.deltaY === 0 && e.deltaX === 0) {
        return;
      }

      const currentTime = Date.now();
      if (currentTime - lastScrollTimeRef.current < scrollConfigRef.current.interval) {
        return;
      }

      flushMouseMove();
      const coord = getCoordinate(e);
      lastPosRef.current = coord;
      syncNormalizedFromHex(coord.x, coord.y, false);
      const dir = scrollConfigRef.current.direction;
      const deltaY = (e.deltaY !== 0 ? (e.deltaY > 0 ? 1 : -1) : 0) * dir;
      const deltaX = (e.deltaX !== 0 ? (e.deltaX > 0 ? -1 : 1) : 0) * dir;
      handleMouseEvent({ type: 'wheel', deltaY, deltaX });
      lastScrollTimeRef.current = currentTime;
    }

    function handleWindowBlur() {
      releaseMouse();
    }

    function handleWindowMouseUp(e: MouseEvent) {
      if (mouseRef.current.hasPressedButtons) {
        flushMouseMove();
        const coord = getCoordinate(e);
        lastPosRef.current = coord;
        syncNormalizedFromHex(coord.x, coord.y, false);
        handleMouseEvent({ type: 'mouseup', button: e.button });
      }
    }

    function handleVisibilityChange() {
      if (document.hidden) {
        releaseMouse();
      }
    }

    const touchController = createTouchGestureController({
      getTouchMode: () => touchModeRef.current,
      getScrollConfig: () => scrollConfigRef.current,
      getZoom: () => zoomRef.current,
      setZoom: (next) => {
        zoomRef.current = next;
        setZoom(next);
      },
      onDirectMove: (clientX, clientY) => {
        const coord = getCoordinate({ clientX, clientY });
        syncNormalizedFromHex(coord.x, coord.y, false);
        return handleMouseEvent({ type: 'move', x: coord.x, y: coord.y });
      },
      onRelativeMove: (dxCss, dyCss) => {
        const box = getRenderedMediaBox(screen, rotationRef.current);
        const currentScale = Math.max(1, zoomRef.current.scale);
        const baseWidth = Math.max(220, box.width / currentScale);
        const baseHeight = Math.max(160, box.height / currentScale);
        // Square-root zoom damping gives finer precision when zoomed in without needing excessive swipes
        const precisionFactor = Math.sqrt(currentScale);

        const normDx = dxCss / (baseWidth * precisionFactor);
        const normDy = dyCss / (baseHeight * precisionFactor);
        const rotated = inverseRotateDelta(normDx, normDy, rotationRef.current);

        const nextX = Math.max(0, Math.min(1, floatPosRef.current.x + rotated.x));
        const nextY = Math.max(0, Math.min(1, floatPosRef.current.y + rotated.y));
        floatPosRef.current = { x: nextX, y: nextY };
        pendingTrackpadPos = { x: nextX, y: nextY };

        if (moveRafId === null) {
          moveRafId = requestAnimationFrame(flushMouseMove);
        }
        return true;
      },
      onButton: (type, button) => {
        flushMouseMove();
        return handleMouseEvent({ type, button });
      },
      onWheel: (deltaY, deltaX, clientX, clientY) => {
        flushMouseMove();
        if (touchModeRef.current === 'direct') {
          const coord = getCoordinate({ clientX, clientY });
          lastPosRef.current = coord;
          syncNormalizedFromHex(coord.x, coord.y, false);
        }
        handleMouseEvent({ type: 'wheel', deltaY, deltaX });
      },
      onResetButtons: () => {
        releaseMouse({ cancelTouchSequence: false });
      }
    });

    function releaseMouse(options: ReleaseMouseOptions = {}) {
      flushMouseMove();
      const { force = false, cancelTouchSequence = true } = options;
      const mouse = mouseRef.current;
      const hadPressedButtons = mouse.hasPressedButtons;
      const report = mouse.reset(lastPosRef.current.x, lastPosRef.current.y);

      touchController.cancel(cancelTouchSequence);
      lastScrollTimeRef.current = 0;

      if (hadPressedButtons || force) {
        sendMouseRelease('absolute', report);
      }
    }

    function handleMouseEvent(event: MouseAbsoluteEvent): boolean {
      let report: Uint8Array;
      const mouse = mouseRef.current;

      switch (event.type) {
        case 'mousedown':
          mouse.buttonDown(event.button);
          report = mouse.buildButtonReport(lastPosRef.current.x, lastPosRef.current.y);
          break;
        case 'mouseup':
          mouse.buttonUp(event.button);
          report = mouse.buildButtonReport(lastPosRef.current.x, lastPosRef.current.y);
          break;
        case 'wheel':
          report = mouse.buildReport(
            lastPosRef.current.x,
            lastPosRef.current.y,
            event.deltaY,
            event.deltaX || 0
          );
          break;
        case 'move':
          report = mouse.buildReport(event.x, event.y);
          lastPosRef.current = { x: event.x, y: event.y };
          break;
        default:
          report = mouse.buildReport(lastPosRef.current.x, lastPosRef.current.y);
          break;
      }

      const sent = sendMouseReport('absolute', report);
      if (!sent && (event.type === 'mouseup' || mouse.hasPressedButtons)) {
        releaseMouse({ force: true });
      }

      return sent;
    }

    function getCoordinate(event: { clientX: number; clientY: number }) {
      const box = getRenderedMediaBox(screen, rotationRef.current);
      const rawX = (event.clientX - box.left) / box.width;
      const rawY = (event.clientY - box.top) / box.height;
      const { x, y } = inverseRotatePoint(rawX, rawY, rotationRef.current);

      const finalX = Math.max(0, Math.min(1, x));
      const finalY = Math.max(0, Math.min(1, y));

      // Map rendered video space onto the GS2 15-bit absolute coordinate range.
      const hexX = Math.round(0x7fff * finalX);
      const hexY = Math.round(0x7fff * finalY);

      return { x: hexX, y: hexY };
    }

    screen.addEventListener('mousedown', handleMouseDown);
    screen.addEventListener('mouseup', handleMouseUp);
    screen.addEventListener('mousemove', handleMouseMove);
    screen.addEventListener('wheel', handleWheel, { passive: false });
    screen.addEventListener('click', disableEvent);
    screen.addEventListener('contextmenu', disableEvent);
    window.addEventListener('blur', handleWindowBlur);
    window.addEventListener('mouseup', handleWindowMouseUp);
    window.addEventListener('mousemove', handleWindowMouseMove);
    document.addEventListener('visibilitychange', handleVisibilityChange);

    const detachTouch = touchController.attach(touchSurface);
    const unregisterMouseReleaseHandler = registerMouseReleaseHandler(() => releaseMouse());
    const unregisterButtonHandler = registerMouseButtonHandler((type, button) => {
      flushMouseMove();
      handleMouseEvent({ type, button });
    });

    return () => {
      if (moveRafId !== null) {
        cancelAnimationFrame(moveRafId);
        moveRafId = null;
      }
      pendingClientPos = null;
      pendingTrackpadPos = null;

      releaseMouse();
      detachTouch();
      unregisterMouseReleaseHandler();
      unregisterButtonHandler();

      screen.removeEventListener('mousemove', handleMouseMove);
      screen.removeEventListener('mousedown', handleMouseDown);
      screen.removeEventListener('mouseup', handleMouseUp);
      screen.removeEventListener('wheel', handleWheel);
      screen.removeEventListener('click', disableEvent);
      screen.removeEventListener('contextmenu', disableEvent);
      window.removeEventListener('blur', handleWindowBlur);
      window.removeEventListener('mouseup', handleWindowMouseUp);
      window.removeEventListener('mousemove', handleWindowMouseMove);
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, [setVirtualCursor, setZoom, videoMode]);

  function disableEvent(event: Event) {
    event.preventDefault();
    event.stopPropagation();
  }

  return <></>;
};
