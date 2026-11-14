import React, { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Button, Divider } from 'antd';
import clsx from 'clsx';
import { useAtomValue, useStore } from 'jotai';
import { ArrowUpDownIcon, LockIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import { hasTouchInput } from '@/lib/touch-device.ts';
import { getRenderedMediaBox, getScreenElement, rotatePoint } from '@/lib/video-transform.ts';
import { isMobileKeyboardOpenAtom } from '@/jotai/keyboard.ts';
import {
  isZoomScrollModeAtom,
  mouseModeAtom,
  showMobileMouseButtonsAtom,
  touchModeAtom,
  virtualCursorAtom,
  virtualCursorVisibleAtom
} from '@/jotai/mouse.ts';
import { videoModeAtom, videoParametersAtom, viewportZoomAtom } from '@/jotai/screen.ts';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

import { onMouseButtonsReleased, triggerMouseButtonAction } from './lifecycle.ts';

export const MobileMouseControls = () => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();
  // Also on touchscreen laptops: touch handlers run there and trackpad mode needs the cursor.
  const hasTouch = isTouchDevice || hasTouchInput();
  const store = useStore();
  const mouseMode = useAtomValue(mouseModeAtom);
  const touchMode = useAtomValue(touchModeAtom);
  const showButtons = useAtomValue(showMobileMouseButtonsAtom);
  const virtualCursorVisible = useAtomValue(virtualCursorVisibleAtom);
  const videoMode = useAtomValue(videoModeAtom);
  const videoParameters = useAtomValue(videoParametersAtom);
  const isMobileKeyboardOpen = useAtomValue(isMobileKeyboardOpenAtom);
  const isZoomScrollMode = useAtomValue(isZoomScrollModeAtom);

  const [dragLocked, setDragLocked] = useState(false);
  const cursorRef = useRef<HTMLDivElement | null>(null);
  const rotationRef = useRef(videoParameters.rotation);
  rotationRef.current = videoParameters.rotation;
  const pressedButtonsRef = useRef<Set<number>>(new Set());
  const dragLockedRef = useRef(false);
  dragLockedRef.current = dragLocked;

  const isButtonBarVisible = showButtons && !isMobileKeyboardOpen;

  useEffect(() => {
    if (!isButtonBarVisible) {
      for (const btn of pressedButtonsRef.current) {
        triggerMouseButtonAction('mouseup', btn);
      }
      pressedButtonsRef.current.clear();

      if (dragLockedRef.current) {
        triggerMouseButtonAction('mouseup', 0);
        setDragLocked(false);
      }
    }
  }, [isButtonBarVisible]);

  // The mouse layer force-released every button (blur, hidden tab, disconnect, failed send,
  // mode switch): the host no longer holds anything, so drop held/locked UI state to match.
  useEffect(() => {
    return onMouseButtonsReleased(() => {
      pressedButtonsRef.current.clear();
      dragLockedRef.current = false;
      setDragLocked(false);
    });
  }, []);

  useEffect(() => {
    const pressedSet = pressedButtonsRef.current;
    return () => {
      for (const btn of pressedSet) {
        triggerMouseButtonAction('mouseup', btn);
      }
      pressedSet.clear();
      if (dragLockedRef.current) {
        triggerMouseButtonAction('mouseup', 0);
      }
    };
  }, []);

  // Project normalized host coordinates (0..1) onto the rendered media element on screen.
  // The cursor moves every animation frame while gliding, so subscribe once per overlay
  // lifetime and write the transform directly in rAF instead of re-rendering/re-subscribing.
  const showCursorOverlay =
    hasTouch && virtualCursorVisible && touchMode === 'trackpad' && mouseMode === 'absolute';

  useLayoutEffect(() => {
    const el = cursorRef.current;
    if (!showCursorOverlay || !el) return;

    const screen = getScreenElement();
    let rafId: number | null = null;

    const updatePosition = () => {
      rafId = null;
      const currentScreen = getScreenElement();
      if (!currentScreen) {
        el.style.visibility = 'hidden';
        return;
      }

      const cursor = store.get(virtualCursorAtom);
      const rotation = rotationRef.current;
      const box = getRenderedMediaBox(currentScreen, rotation);
      const rotated = rotatePoint(cursor.x, cursor.y, rotation);
      const x = box.left + rotated.x * box.width;
      const y = box.top + rotated.y * box.height;
      el.style.visibility = '';
      el.style.transform = `translate3d(${x}px, ${y}px, 0)`;
    };

    const schedule = () => {
      if (rafId === null) {
        rafId = requestAnimationFrame(updatePosition);
      }
    };

    updatePosition();

    const unsubscribeCursor = store.sub(virtualCursorAtom, schedule);
    const unsubscribeZoom = store.sub(viewportZoomAtom, schedule);
    const vv = window.visualViewport;
    const resizeObserver = new ResizeObserver(schedule);
    if (screen) resizeObserver.observe(screen);

    window.addEventListener('resize', schedule);
    vv?.addEventListener('resize', schedule);
    vv?.addEventListener('scroll', schedule);
    screen?.addEventListener('loadedmetadata', schedule);
    screen?.addEventListener('load', schedule);

    return () => {
      if (rafId !== null) cancelAnimationFrame(rafId);
      unsubscribeCursor();
      unsubscribeZoom();
      resizeObserver.disconnect();
      window.removeEventListener('resize', schedule);
      vv?.removeEventListener('resize', schedule);
      vv?.removeEventListener('scroll', schedule);
      screen?.removeEventListener('loadedmetadata', schedule);
      screen?.removeEventListener('load', schedule);
    };
  }, [showCursorOverlay, store, videoMode, videoParameters.rotation, videoParameters.scale]);

  if (!hasTouch) {
    return null;
  }

  function handlePointerPressStart(e: React.PointerEvent<HTMLElement>, button: number) {
    e.preventDefault();
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      // Ignore if pointer capture is unsupported on synthetic pointers
    }

    if (button === 0 && dragLockedRef.current) {
      triggerMouseButtonAction('mouseup', 0);
      setDragLocked(false);
      return;
    }

    if (!pressedButtonsRef.current.has(button)) {
      pressedButtonsRef.current.add(button);
      triggerMouseButtonAction('mousedown', button);
    }
  }

  function handlePointerPressEnd(button: number) {
    if (button === 0 && dragLockedRef.current) {
      return;
    }
    if (pressedButtonsRef.current.delete(button)) {
      triggerMouseButtonAction('mouseup', button);
    }
  }

  function toggleDragLock() {
    if (dragLockedRef.current) {
      pressedButtonsRef.current.delete(0);
      triggerMouseButtonAction('mouseup', 0);
      setDragLocked(false);
    } else {
      pressedButtonsRef.current.delete(0);
      triggerMouseButtonAction('mousedown', 0);
      setDragLocked(true);
    }
  }

  const btnBaseClass = 'flex h-[30px] items-center justify-center px-3 text-xs font-medium text-neutral-300 hover:text-white';

  return (
    <>
      {/* Transient non-interactive HUD badge confirming 2-finger hold-to-scroll while zoomed */}
      {isZoomScrollMode && (
        <div
          aria-live="polite"
          className="pointer-events-none fixed left-1/2 z-[985] flex h-[28px] -translate-x-1/2 select-none items-center gap-1.5 rounded-full border border-blue-400/40 bg-neutral-900/85 px-3 text-xs font-medium text-blue-300 shadow-lg backdrop-blur-sm"
          style={{
            top: 'max(54px, calc(var(--safe-top) + 50px))'
          }}
        >
          <ArrowUpDownIcon size={13} aria-hidden="true" />
          <span>{t('mouse.scrollMode', { defaultValue: 'Scroll' })}</span>
        </div>
      )}

      {/* Local zero-latency cursor indicator in Trackpad + Absolute mode */}
      {showCursorOverlay && (
        <div
          ref={cursorRef}
          aria-hidden="true"
          className="pointer-events-none fixed left-0 top-0 z-[950]"
        >
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            className="-translate-x-[2px] -translate-y-[2px] drop-shadow-[0_1px_3px_rgba(0,0,0,0.85)]"
          >
            <path
              d="M4 3L11.5 20L14.2 13.5L20.5 11L4 3Z"
              fill="rgba(255,255,255,0.95)"
              stroke="#111827"
              strokeWidth="1.8"
              strokeLinejoin="round"
            />
          </svg>
        </div>
      )}

      {/* Optional floating thumb mouse buttons using Ant Design Button */}
      {isButtonBarVisible && (
        <div
          className="fixed left-1/2 z-[990] flex h-[38px] -translate-x-1/2 touch-none select-none items-center rounded bg-neutral-800/80 px-1.5 backdrop-blur-sm"
          style={{
            bottom: 'max(12px, calc(var(--safe-bottom) + 8px))'
          }}
        >
          <Button
            type="text"
            size="small"
            onPointerDown={(e) => handlePointerPressStart(e, 0)}
            onPointerUp={() => handlePointerPressEnd(0)}
            onPointerCancel={() => handlePointerPressEnd(0)}
            onLostPointerCapture={() => handlePointerPressEnd(0)}
            className={clsx(btnBaseClass, 'min-w-[52px]')}
          >
            {t('mouse.leftBtn', { defaultValue: 'Left' })}
          </Button>

          <Divider type="vertical" style={{ margin: '0 2px' }} />

          <Button
            type="text"
            size="small"
            onPointerDown={(e) => handlePointerPressStart(e, 1)}
            onPointerUp={() => handlePointerPressEnd(1)}
            onPointerCancel={() => handlePointerPressEnd(1)}
            onLostPointerCapture={() => handlePointerPressEnd(1)}
            className={clsx(btnBaseClass, 'min-w-[44px]')}
          >
            {t('mouse.midBtn', { defaultValue: 'Mid' })}
          </Button>

          <Divider type="vertical" style={{ margin: '0 2px' }} />

          <Button
            type="text"
            size="small"
            onPointerDown={(e) => handlePointerPressStart(e, 2)}
            onPointerUp={() => handlePointerPressEnd(2)}
            onPointerCancel={() => handlePointerPressEnd(2)}
            onLostPointerCapture={() => handlePointerPressEnd(2)}
            className={clsx(btnBaseClass, 'min-w-[52px]')}
          >
            {t('mouse.rightBtn', { defaultValue: 'Right' })}
          </Button>

          <Divider type="vertical" style={{ margin: '0 2px' }} />

          <Button
            size="small"
            color={dragLocked ? 'primary' : 'default'}
            variant={dragLocked ? 'filled' : 'text'}
            aria-pressed={dragLocked}
            aria-label={t('mouse.dragLock', { defaultValue: 'Drag Lock' })}
            icon={<LockIcon size={13} aria-hidden="true" />}
            onClick={toggleDragLock}
            className={clsx(
              'flex h-[30px] min-w-[56px] items-center justify-center px-2.5 text-xs font-medium',
              !dragLocked && 'text-neutral-300 hover:text-white'
            )}
          >
            {t('mouse.drag', { defaultValue: 'Drag' })}
          </Button>
        </div>
      )}
    </>
  );
};
