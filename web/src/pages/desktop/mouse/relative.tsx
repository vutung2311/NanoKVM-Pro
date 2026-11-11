import { useEffect, useRef } from 'react';
import { message } from 'antd';
import { useAtom, useAtomValue } from 'jotai';
import { useTranslation } from 'react-i18next';

import { MouseReportRelative } from '@/lib/mouse.ts';
import { getScreenElement, inverseRotateDelta } from '@/lib/video-transform.ts';
import { scrollDirectionAtom, scrollIntervalAtom, touchModeAtom } from '@/jotai/mouse.ts';
import { videoModeAtom, videoParametersAtom, viewportZoomAtom } from '@/jotai/screen.ts';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

import {
  registerMouseButtonHandler,
  registerMouseReleaseHandler,
  sendMouseRelease,
  sendMouseReport
} from './lifecycle.ts';
import { createTouchGestureController } from './touch-gestures.ts';
import { MouseRelativeEvent } from './types.ts';

export const Relative = () => {
  const { t } = useTranslation();
  const [messageApi, contextHolder] = message.useMessage();
  const isTouchDevice = useTouchDevice();

  const scrollDirection = useAtomValue(scrollDirectionAtom);
  const scrollInterval = useAtomValue(scrollIntervalAtom);
  const touchMode = useAtomValue(touchModeAtom);
  const videoMode = useAtomValue(videoModeAtom);
  const videoParameters = useAtomValue(videoParametersAtom);
  const [zoom, setZoom] = useAtom(viewportZoomAtom);

  const mouseRef = useRef(new MouseReportRelative());
  const isLockedRef = useRef(false);
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
    if (!isTouchDevice) {
      messageApi.open({
        key: 'requestPointer',
        type: 'info',
        content: t('mouse.requestPointer'),
        duration: 3,
        style: {
          marginTop: '40vh'
        }
      });
    }
  }, [isTouchDevice, messageApi, t]);

  useEffect(() => {
    const screen = getScreenElement();
    if (!screen) return;
    const touchSurface = document.getElementById('screen-viewport') ?? (screen as HTMLElement);

    let pendingDeltaX = 0;
    let pendingDeltaY = 0;
    let moveRafId: number | null = null;

    function handleMouseEvent(event: MouseRelativeEvent): boolean {
      let report: Uint8Array;
      const mouse = mouseRef.current;

      switch (event.type) {
        case 'mousedown':
          mouse.buttonDown(event.button);
          report = mouse.buildButtonReport();
          break;
        case 'mouseup':
          mouse.buttonUp(event.button);
          report = mouse.buildButtonReport();
          break;
        case 'wheel':
          report = mouse.buildReport(0, 0, event.deltaY, event.deltaX || 0);
          break;
        case 'move':
          report = mouse.buildReport(event.deltaX, event.deltaY);
          break;
        default:
          report = mouse.buildReport(0, 0);
          break;
      }

      const sent = sendMouseReport('relative', report);
      if (!sent && (event.type === 'mouseup' || mouse.hasPressedButtons)) {
        releaseMouse(true);
      }
      return sent;
    }

    function handleContextMenu(event: Event) {
      event.preventDefault();
    }

    function flushMouseMove() {
      if (moveRafId !== null) {
        cancelAnimationFrame(moveRafId);
        moveRafId = null;
      }

      // Send whole pixels; keep the sub-pixel remainder for the next frame.
      let dx = Math.round(pendingDeltaX);
      let dy = Math.round(pendingDeltaY);
      pendingDeltaX -= dx;
      pendingDeltaY -= dy;

      // A HID report carries at most ±127 per axis. Split large batches into
      // several reports instead of clamping, so fast flicks don't lose distance.
      while (dx !== 0 || dy !== 0) {
        const stepX = Math.max(-127, Math.min(127, dx));
        const stepY = Math.max(-127, Math.min(127, dy));
        handleMouseEvent({ type: 'move', deltaX: stepX, deltaY: stepY });
        dx -= stepX;
        dy -= stepY;
      }
    }

    function handleMouseClick(event: MouseEvent) {
      disableEvent(event);

      if (!isLockedRef.current && typeof screen?.requestPointerLock === 'function') {
        screen.requestPointerLock();
      }
    }

    function handleMouseDown(e: MouseEvent) {
      disableEvent(e);
      flushMouseMove();
      handleMouseEvent({ type: 'mousedown', button: e.button });
    }

    function handleMouseUp(e: MouseEvent) {
      disableEvent(e);
      flushMouseMove();
      handleMouseEvent({ type: 'mouseup', button: e.button });
    }

    function handleMouseMove(e: any) {
      disableEvent(e);

      const x = e.movementX || e.mozMovementX || e.webkitMovementX || 0;
      const y = e.movementY || e.mozMovementY || e.webkitMovementY || 0;
      if (x === 0 && y === 0) return;

      const deltaX = Math.abs(x * window.devicePixelRatio) < 10 ? x * 2 : x;
      const deltaY = Math.abs(y * window.devicePixelRatio) < 10 ? y * 2 : y;
      const delta = inverseRotateDelta(deltaX, deltaY, rotationRef.current);

      pendingDeltaX += delta.x;
      pendingDeltaY += delta.y;

      if (moveRafId === null) {
        moveRafId = requestAnimationFrame(flushMouseMove);
      }
    }

    function handleMouseWheel(e: WheelEvent) {
      disableEvent(e);

      if (e.deltaY === 0 && e.deltaX === 0) {
        return;
      }

      const currentTime = Date.now();
      if (currentTime - lastScrollTimeRef.current < scrollConfigRef.current.interval) {
        return;
      }

      flushMouseMove();
      const dir = scrollConfigRef.current.direction;
      const deltaY = (e.deltaY !== 0 ? (e.deltaY > 0 ? 1 : -1) : 0) * dir;
      const deltaX = (e.deltaX !== 0 ? (e.deltaX > 0 ? -1 : 1) : 0) * dir;
      handleMouseEvent({ type: 'wheel', deltaY, deltaX });
      lastScrollTimeRef.current = currentTime;
    }

    const touchController = createTouchGestureController({
      getTouchMode: () => 'trackpad',
      getScrollConfig: () => scrollConfigRef.current,
      getZoom: () => zoomRef.current,
      setZoom: (next) => {
        zoomRef.current = next;
        setZoom(next);
      },
      onRelativeMove: (dxCss, dyCss) => {
        const damping = 1 / Math.sqrt(Math.max(1, zoomRef.current.scale));
        const delta = inverseRotateDelta(dxCss * 1.6 * damping, dyCss * 1.6 * damping, rotationRef.current);
        pendingDeltaX += delta.x;
        pendingDeltaY += delta.y;

        if (moveRafId === null) {
          moveRafId = requestAnimationFrame(flushMouseMove);
        }
        return true;
      },
      onButton: (type, button) => {
        flushMouseMove();
        return handleMouseEvent({ type, button });
      },
      onWheel: (deltaY, deltaX) => {
        flushMouseMove();
        handleMouseEvent({ type: 'wheel', deltaY, deltaX });
      },
      onResetButtons: () => {
        releaseMouse(false, false);
      }
    });

    function handlePointerLockChange() {
      const wasLocked = isLockedRef.current;
      const isLocked = document.pointerLockElement === screen;
      isLockedRef.current = isLocked;

      if (wasLocked && !isLocked) {
        releaseMouse();
      }
    }

    function handleWindowBlur() {
      releaseMouseAndExitPointerLock();
    }

    function handleVisibilityChange() {
      if (document.hidden) {
        releaseMouseAndExitPointerLock();
      }
    }

    function releaseMouse(force = false, cancelTouch = true) {
      flushMouseMove();
      const mouse = mouseRef.current;
      const hadPressedButtons = mouse.hasPressedButtons;
      const report = mouse.reset();
      lastScrollTimeRef.current = 0;
      touchController.cancel(cancelTouch);

      if (hadPressedButtons || force) {
        sendMouseRelease('relative', report);
      }
    }

    function releaseMouseAndExitPointerLock() {
      releaseMouse();

      if (document.pointerLockElement === screen) {
        document.exitPointerLock();
      }

      isLockedRef.current = false;
    }

    screen.addEventListener('click', handleMouseClick);
    screen.addEventListener('mousedown', handleMouseDown);
    screen.addEventListener('mouseup', handleMouseUp);
    screen.addEventListener('mousemove', handleMouseMove);
    screen.addEventListener('wheel', handleMouseWheel, { passive: false });
    screen.addEventListener('contextmenu', handleContextMenu);
    document.addEventListener('pointerlockchange', handlePointerLockChange);
    window.addEventListener('blur', handleWindowBlur);
    document.addEventListener('visibilitychange', handleVisibilityChange);

    const detachTouch = touchController.attach(touchSurface);
    const unregisterMouseReleaseHandler = registerMouseReleaseHandler(releaseMouseAndExitPointerLock);
    const unregisterButtonHandler = registerMouseButtonHandler((type, button) => {
      flushMouseMove();
      handleMouseEvent({ type, button });
    });

    return () => {
      if (moveRafId !== null) {
        cancelAnimationFrame(moveRafId);
        moveRafId = null;
      }
      pendingDeltaX = 0;
      pendingDeltaY = 0;

      releaseMouseAndExitPointerLock();
      detachTouch();
      unregisterMouseReleaseHandler();
      unregisterButtonHandler();

      screen.removeEventListener('click', handleMouseClick);
      screen.removeEventListener('mousemove', handleMouseMove);
      screen.removeEventListener('mousedown', handleMouseDown);
      screen.removeEventListener('mouseup', handleMouseUp);
      screen.removeEventListener('wheel', handleMouseWheel);
      screen.removeEventListener('contextmenu', handleContextMenu);
      document.removeEventListener('pointerlockchange', handlePointerLockChange);
      window.removeEventListener('blur', handleWindowBlur);
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, [setZoom, videoMode]);

  function disableEvent(event: Event) {
    event.preventDefault();
    event.stopPropagation();
  }

  return <>{contextHolder}</>;
};
