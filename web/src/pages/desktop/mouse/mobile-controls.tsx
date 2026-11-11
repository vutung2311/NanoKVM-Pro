import React, { useEffect, useRef, useState } from 'react';
import { Button, Divider } from 'antd';
import clsx from 'clsx';
import { useAtomValue } from 'jotai';
import { LockIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import { getRenderedMediaBox, getScreenElement, rotatePoint } from '@/lib/video-transform.ts';
import { isMobileKeyboardOpenAtom } from '@/jotai/keyboard.ts';
import {
  mouseModeAtom,
  showMobileMouseButtonsAtom,
  touchModeAtom,
  virtualCursorAtom
} from '@/jotai/mouse.ts';
import { videoModeAtom, videoParametersAtom, viewportZoomAtom } from '@/jotai/screen.ts';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

import { triggerMouseButtonAction } from './lifecycle.ts';

export const MobileMouseControls = () => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();
  const mouseMode = useAtomValue(mouseModeAtom);
  const touchMode = useAtomValue(touchModeAtom);
  const showButtons = useAtomValue(showMobileMouseButtonsAtom);
  const virtualCursor = useAtomValue(virtualCursorAtom);
  const videoMode = useAtomValue(videoModeAtom);
  const videoParameters = useAtomValue(videoParametersAtom);
  const zoom = useAtomValue(viewportZoomAtom);
  const isMobileKeyboardOpen = useAtomValue(isMobileKeyboardOpenAtom);

  const [dragLocked, setDragLocked] = useState(false);
  const [cursorScreenPos, setCursorScreenPos] = useState<{ x: number; y: number } | null>(null);
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

  // Project normalized host coordinates (0..1) onto the rendered media element on screen
  useEffect(() => {
    if (
      !isTouchDevice ||
      !virtualCursor.visible ||
      touchMode !== 'trackpad' ||
      mouseMode !== 'absolute'
    ) {
      setCursorScreenPos(null);
      return;
    }

    const screen = getScreenElement();
    if (!screen) {
      setCursorScreenPos(null);
      return;
    }

    const updatePosition = () => {
      const currentScreen = getScreenElement();
      if (!currentScreen) {
        setCursorScreenPos(null);
        return;
      }

      const box = getRenderedMediaBox(currentScreen, videoParameters.rotation);
      const rotated = rotatePoint(virtualCursor.x, virtualCursor.y, videoParameters.rotation);
      setCursorScreenPos({
        x: box.left + rotated.x * box.width,
        y: box.top + rotated.y * box.height
      });
    };

    updatePosition();

    const vv = window.visualViewport;
    const resizeObserver = new ResizeObserver(updatePosition);
    resizeObserver.observe(screen);

    window.addEventListener('resize', updatePosition);
    vv?.addEventListener('resize', updatePosition);
    vv?.addEventListener('scroll', updatePosition);
    screen.addEventListener('loadedmetadata', updatePosition);
    screen.addEventListener('load', updatePosition);

    return () => {
      resizeObserver.disconnect();
      window.removeEventListener('resize', updatePosition);
      vv?.removeEventListener('resize', updatePosition);
      vv?.removeEventListener('scroll', updatePosition);
      screen.removeEventListener('loadedmetadata', updatePosition);
      screen.removeEventListener('load', updatePosition);
    };
  }, [
    isTouchDevice,
    mouseMode,
    touchMode,
    videoMode,
    videoParameters.rotation,
    videoParameters.scale,
    virtualCursor.visible,
    virtualCursor.x,
    virtualCursor.y,
    zoom.scale,
    zoom.x,
    zoom.y
  ]);

  if (!isTouchDevice) {
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
      {/* Local zero-latency cursor indicator in Trackpad + Absolute mode */}
      {cursorScreenPos && (
        <div
          aria-hidden="true"
          className="pointer-events-none fixed left-0 top-0 z-[950]"
          style={{
            transform: `translate3d(${cursorScreenPos.x}px, ${cursorScreenPos.y}px, 0)`
          }}
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
