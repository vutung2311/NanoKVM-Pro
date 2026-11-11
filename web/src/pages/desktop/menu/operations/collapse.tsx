import { Button, Tooltip } from 'antd';
import { XIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

interface CollapseProps {
  toggleMenu(expanded: boolean): void;
}

export const Collapse = ({ toggleMenu }: CollapseProps) => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();
  const label = t('menu.collapse', { defaultValue: 'Collapse menu' });

  const button = (
    <Button
      type="text"
      size="small"
      aria-label={label}
      icon={<XIcon size={18} aria-hidden="true" />}
      className="kvm-touch-target flex size-[30px] shrink-0 items-center justify-center p-0 text-neutral-300 hover:text-white"
      onClick={() => toggleMenu(false)}
    />
  );

  if (isTouchDevice) {
    return button;
  }

  return (
    <Tooltip title={label} placement="bottom" mouseEnterDelay={0.6}>
      {button}
    </Tooltip>
  );
};
