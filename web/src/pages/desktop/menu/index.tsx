import { useEffect, useRef, useState } from 'react';
import { Button, Divider } from 'antd';
import clsx from 'clsx';
import { useAtom, useAtomValue, useSetAtom } from 'jotai';
import {
  GripVerticalIcon,
  HandIcon,
  KeyboardIcon,
  MousePointerClickIcon,
  TouchpadIcon
} from 'lucide-react';
import Draggable, { DraggableData, DraggableEvent } from 'react-draggable';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/vm.ts';
import * as storage from '@/lib/localstorage.ts';
import { toggleMobileKeyboard } from '@/lib/mobile-keyboard-focus.ts';
import { isMobileKeyboardOpenAtom } from '@/jotai/keyboard.ts';
import {
  showMobileMouseButtonsAtom,
  touchModeAtom,
  virtualCursorAtom
} from '@/jotai/mouse.ts';
import { menuDisabledItemsAtom } from '@/jotai/settings.ts';
import { useMenuBounds } from '@/hooks/useMenuBounds.ts';
import { useMenuVisibility } from '@/hooks/useMenuVisibility.ts';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

import { AIAssistant } from './assistant';
import { Fullscreen } from './fullscreen';
import { Image } from './image';
import { Keyboard } from './keyboard';
import { Microphone } from './microphone';
import { Mouse } from './mouse';
import { Collapse, Expand } from './operations';
import { Power } from './power';
import { Screen } from './screen';
import { Script } from './script';
import { Settings } from './settings';
import { Terminal } from './terminal';
import { Volume } from './volume';
import { Wol } from './wol';
import { ZoomResetButton } from './zoom-reset.tsx';

export const Menu = () => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();
  const nodeRef = useRef<HTMLDivElement | null>(null);

  const menuDisabledItems = useAtomValue(menuDisabledItemsAtom);
  const setMenuDisabledItems = useSetAtom(menuDisabledItemsAtom);

  const isMobileKeyboardOpen = useAtomValue(isMobileKeyboardOpenAtom);
  const [touchMode, setTouchMode] = useAtom(touchModeAtom);
  const [showMouseButtons, setShowMouseButtons] = useAtom(showMobileMouseButtonsAtom);
  const setVirtualCursor = useSetAtom(virtualCursorAtom);

  const [isInitialized, setIsInitialized] = useState(false);

  const { isMenuExpanded, isMenuHidden, handleHovered, handleMoved, setIsMenuExpanded } =
    useMenuVisibility();

  const menuBounds = useMenuBounds(nodeRef, isMenuExpanded);

  useEffect(() => {
    api
      .getMenuBarConfig()
      .then((rsp) => {
        if (rsp.code === 0 && rsp.data?.disabledItems?.length) {
          setMenuDisabledItems(rsp.data.disabledItems);
          return;
        }

        // compatible with old versions
        const items = storage.getMenuDisabledItems();
        setMenuDisabledItems(items);
      })
      .finally(() => {
        setIsInitialized(true);
      });
  }, [setMenuDisabledItems]);

  function onDragStop(_e: DraggableEvent, data: DraggableData) {
    if (data.x === 0 && data.y === 0) return;
    handleMoved();
  }

  function isEnabled(item: string) {
    return !menuDisabledItems.includes(item);
  }

  function flipTouchMode() {
    const next = touchMode === 'trackpad' ? 'direct' : 'trackpad';
    setTouchMode(next);
    storage.setTouchMode(next);
    if (next === 'direct') {
      setVirtualCursor((prev) => ({ ...prev, visible: false }));
    }
  }

  function flipMouseButtons() {
    const next = !showMouseButtons;
    setShowMouseButtons(next);
    storage.setMobileMouseButtons(next);
  }

  return (
    <Draggable
      nodeRef={nodeRef}
      bounds={menuBounds}
      handle="strong"
      positionOffset={{ x: '-50%', y: '0%' }}
      onStop={onDragStop}
    >
      <div
        ref={nodeRef}
        className={clsx(
          'fixed left-1/2 z-[1000] max-w-[calc(100dvw-12px)] -translate-x-1/2 transition-opacity duration-300',
          isInitialized ? 'opacity-100' : 'opacity-0'
        )}
        style={{
          top: 'max(10px, calc(var(--safe-top) + 6px))'
        }}
        onMouseEnter={() => handleHovered(true)}
        onMouseLeave={() => handleHovered(false)}
        onBlur={() => handleHovered(false)}
      >
        {/* Trigger area for auto-show when hidden on desktop */}
        {isMenuExpanded && !isTouchDevice && (
          <div className="absolute -top-[10px] left-0 right-0 h-[46px] w-full bg-transparent" />
        )}

        {/* Menubar */}
        <div className="flex w-full justify-center">
          <div
            className={clsx(
              'max-w-[calc(100dvw-12px)] items-center rounded bg-neutral-800/80 pl-1 pr-1.5 backdrop-blur-sm transition-all duration-300',
              isTouchDevice ? 'h-[38px]' : 'h-[36px]',
              isMenuExpanded ? 'flex' : 'hidden',
              isMenuHidden ? '-translate-y-[110%] opacity-80' : 'translate-y-0 opacity-100'
            )}
          >
            <strong className="shrink-0">
              <div className="kvm-touch-target flex h-[30px] cursor-move select-none items-center justify-center pl-1 text-neutral-500">
                <GripVerticalIcon size={18} aria-hidden="true" />
              </div>
            </strong>
            <Divider type="vertical" className="shrink-0" />

            {/* Mobile-first one-tap controls using Ant Design Button */}
            {isTouchDevice && (
              <>
                <div className="flex shrink-0 items-center gap-1">
                  <Button
                    size="small"
                    color={isMobileKeyboardOpen ? 'primary' : 'default'}
                    variant={isMobileKeyboardOpen ? 'filled' : 'text'}
                    aria-label={t('keyboard.mobileType', { defaultValue: 'Open phone keyboard' })}
                    aria-pressed={isMobileKeyboardOpen}
                    icon={<KeyboardIcon size={18} aria-hidden="true" />}
                    onMouseDown={(e) => {
                      if (isMobileKeyboardOpen) {
                        e.preventDefault();
                      }
                    }}
                    onClick={() => toggleMobileKeyboard()}
                    className={clsx(
                      'kvm-touch-target flex h-[30px] w-[30px] shrink-0 items-center justify-center p-0',
                      !isMobileKeyboardOpen && 'text-neutral-300 hover:text-white'
                    )}
                  />

                  <Button
                    size="small"
                    color={touchMode === 'trackpad' ? 'primary' : 'gold'}
                    variant="text"
                    aria-label={
                      touchMode === 'trackpad'
                        ? t('mouse.trackpad', { defaultValue: 'Trackpad mode' })
                        : t('mouse.directTouch', { defaultValue: 'Direct touch' })
                    }
                    icon={
                      touchMode === 'trackpad' ? (
                        <TouchpadIcon size={18} aria-hidden="true" />
                      ) : (
                        <HandIcon size={18} aria-hidden="true" />
                      )
                    }
                    onClick={flipTouchMode}
                    className="kvm-touch-target flex h-[30px] w-[30px] shrink-0 items-center justify-center p-0"
                  />

                  <Button
                    size="small"
                    color={showMouseButtons ? 'primary' : 'default'}
                    variant={showMouseButtons ? 'filled' : 'text'}
                    aria-label={t('mouse.floatingButtons', {
                      defaultValue: 'On-screen mouse buttons'
                    })}
                    aria-pressed={showMouseButtons}
                    icon={<MousePointerClickIcon size={18} aria-hidden="true" />}
                    onClick={flipMouseButtons}
                    className={clsx(
                      'kvm-touch-target flex h-[30px] w-[30px] shrink-0 items-center justify-center p-0',
                      !showMouseButtons && 'text-neutral-300 hover:text-white'
                    )}
                  />

                  <ZoomResetButton />
                </div>

                <Divider type="vertical" className="shrink-0" />
              </>
            )}

            {/* Scrollable feature tray so narrow phone viewports never clip right-side controls */}
            <div className="no-scrollbar flex min-w-0 items-center gap-0.5 overflow-x-auto">
              <Screen />
              {isEnabled('volume') && <Volume />}
              {isEnabled('microphone') && <Microphone />}
              {['volume', 'microphone'].some(isEnabled) && <Divider type="vertical" />}

              <Keyboard />
              <Mouse />
              <Divider type="vertical" />

              {isEnabled('image') && <Image />}
              {isEnabled('script') && <Script />}
              {isEnabled('assistant') && <AIAssistant />}
              {isEnabled('terminal') && <Terminal />}
              {isEnabled('wol') && <Wol />}

              {['image', 'script', 'assistant', 'terminal', 'wol'].some(isEnabled) && (
                <Divider type="vertical" />
              )}

              {isEnabled('power') && (
                <>
                  <Power />
                  <Divider type="vertical" />
                </>
              )}

              <Settings />
              {isEnabled('fullscreen') && <Fullscreen />}
            </div>

            {isEnabled('collapse') && (
              <>
                <Divider type="vertical" className="shrink-0" />
                <Collapse toggleMenu={setIsMenuExpanded} />
              </>
            )}
          </div>
        </div>

        {/* Menubar expand button */}
        {!isMenuExpanded && <Expand toggleMenu={setIsMenuExpanded} />}
      </div>
    </Draggable>
  );
};
