import { useEffect } from 'react';
import { Divider } from 'antd';
import { useSetAtom } from 'jotai';
import { MouseIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import * as ls from '@/lib/localstorage';
import {
  mouseModeAtom,
  mouseStyleAtom,
  scrollDirectionAtom,
  scrollIntervalAtom,
  showMobileMouseButtonsAtom,
  touchModeAtom
} from '@/jotai/mouse';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';
import { MenuItem } from '@/components/menu-item.tsx';

import { Cursor } from './cursor.tsx';
import { Direction } from './direction.tsx';
import { HidMode } from './hid-mode.tsx';
import { MouseMode } from './mouse-mode.tsx';
import { ResetHid } from './reset-hid.tsx';
import { Speed } from './speed.tsx';
import { TouchMode } from './touch-mode.tsx';

export const Mouse = () => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();

  const setMouseStyle = useSetAtom(mouseStyleAtom);
  const setMouseMode = useSetAtom(mouseModeAtom);
  const setScrollDirection = useSetAtom(scrollDirectionAtom);
  const setScrollInterval = useSetAtom(scrollIntervalAtom);
  const setTouchMode = useSetAtom(touchModeAtom);
  const setShowMobileButtons = useSetAtom(showMobileMouseButtonsAtom);

  useEffect(() => {
    const mouseStyle = ls.getMouseStyle();
    if (mouseStyle) {
      setMouseStyle(mouseStyle);
    }

    const mouseMode = ls.getMouseMode();
    if (mouseMode) {
      setMouseMode(mouseMode);
    }

    const direction = ls.getMouseScrollDirection();
    if (direction) {
      setScrollDirection(direction > 0 ? 1 : -1);
    }

    const interval = ls.getMouseScrollInterval();
    if (interval) {
      setScrollInterval(interval);
    }

    setTouchMode(ls.getTouchMode());
    setShowMobileButtons(ls.getMobileMouseButtons());
  }, [
    setMouseMode,
    setMouseStyle,
    setScrollDirection,
    setScrollInterval,
    setShowMobileButtons,
    setTouchMode
  ]);

  const content = (
    <div className="flex flex-col space-y-1">
      {isTouchDevice && (
        <>
          <TouchMode />
          <Divider style={{ margin: '8px 0' }} />
        </>
      )}

      {!isTouchDevice && <Cursor />}
      <MouseMode />
      <Direction />
      <Speed />
      <Divider style={{ margin: '10px 0' }} />

      <HidMode />
      <ResetHid />
    </div>
  );

  return <MenuItem title={t('mouse.title')} icon={<MouseIcon size={18} />} content={content} />;
};
