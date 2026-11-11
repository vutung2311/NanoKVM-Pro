import clsx from 'clsx';
import { useSetAtom } from 'jotai';
import { KeyboardIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import { toggleMobileKeyboard } from '@/lib/mobile-keyboard-focus.ts';
import { isKeyboardOpenAtom } from '@/jotai/keyboard.ts';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

export const VirtualKeyboard = () => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();
  const setIsKeyboardOpen = useSetAtom(isKeyboardOpenAtom);

  function handleTrigger() {
    if (isTouchDevice) {
      toggleMobileKeyboard();
      return;
    }
    setIsKeyboardOpen((o) => !o);
  }

  return (
    <div
      className={clsx(
        'flex cursor-pointer select-none items-center space-x-2 rounded py-1.5 pl-2 pr-5 hover:bg-neutral-700/70'
      )}
      onClick={handleTrigger}
    >
      <KeyboardIcon size={18} />
      <span>{t('keyboard.virtual')}</span>
    </div>
  );
};
