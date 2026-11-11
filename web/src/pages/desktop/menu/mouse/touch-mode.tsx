import { useAtom, useSetAtom } from 'jotai';
import { CheckIcon, MousePointerClickIcon, TouchpadIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import * as ls from '@/lib/localstorage.ts';
import {
  showMobileMouseButtonsAtom,
  TouchControlMode,
  touchModeAtom,
  virtualCursorAtom
} from '@/jotai/mouse.ts';

export const TouchMode = () => {
  const { t } = useTranslation();

  const [touchMode, setTouchMode] = useAtom(touchModeAtom);
  const [showButtons, setShowButtons] = useAtom(showMobileMouseButtonsAtom);
  const setVirtualCursor = useSetAtom(virtualCursorAtom);

  const modes: { label: string; value: TouchControlMode }[] = [
    {
      label: t('mouse.trackpad', { defaultValue: 'Trackpad mode' }),
      value: 'trackpad'
    },
    {
      label: t('mouse.directTouch', { defaultValue: 'Direct touch' }),
      value: 'direct'
    }
  ];

  function selectMode(mode: TouchControlMode) {
    setTouchMode(mode);
    ls.setTouchMode(mode);
    if (mode === 'direct') {
      setVirtualCursor((prev) => ({ ...prev, visible: false }));
    }
  }

  function toggleButtons() {
    const next = !showButtons;
    setShowButtons(next);
    ls.setMobileMouseButtons(next);
  }

  return (
    <div className="flex flex-col space-y-1">
      <div className="flex items-center space-x-2 px-3 py-1 text-xs font-medium text-neutral-400">
        <TouchpadIcon size={14} aria-hidden="true" />
        <span>{t('mouse.touchControl', { defaultValue: 'Touch control' })}</span>
      </div>

      {modes.map((item) => (
        <div
          key={item.value}
          className="flex cursor-pointer items-center space-x-2 rounded py-1.5 pl-3 pr-5 text-neutral-200 hover:bg-neutral-700/70"
          onClick={() => selectMode(item.value)}
        >
          <div className="flex h-[16px] w-[16px] items-center text-blue-500">
            {touchMode === item.value && <CheckIcon strokeWidth={3} size={16} />}
          </div>
          <span>{item.label}</span>
        </div>
      ))}

      <div
        className="flex cursor-pointer items-center space-x-2 rounded py-1.5 pl-3 pr-5 text-neutral-200 hover:bg-neutral-700/70"
        onClick={toggleButtons}
      >
        <div className="flex h-[16px] w-[16px] items-center text-blue-500">
          {showButtons && <CheckIcon strokeWidth={3} size={16} />}
        </div>
        <MousePointerClickIcon size={15} className="text-neutral-400" aria-hidden="true" />
        <span>{t('mouse.floatingButtons', { defaultValue: 'On-screen mouse buttons' })}</span>
      </div>
    </div>
  );
};
