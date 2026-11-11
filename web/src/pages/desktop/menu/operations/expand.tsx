import { Button, Divider } from 'antd';
import { ChevronRightIcon, GripVerticalIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

interface ExpandProps {
  toggleMenu: (expanded: boolean) => void;
}

export const Expand = ({ toggleMenu }: ExpandProps) => {
  const { t } = useTranslation();

  return (
    <div className="flex items-center rounded-lg bg-neutral-800/80 p-1 backdrop-blur-sm">
      <strong>
        <div className="kvm-touch-target flex size-[26px] cursor-move select-none items-center justify-center text-neutral-500">
          <GripVerticalIcon size={18} aria-hidden="true" />
        </div>
      </strong>
      <Divider type="vertical" style={{ margin: '0 4px' }} />
      <Button
        type="text"
        size="small"
        aria-label={t('menu.expand', { defaultValue: 'Expand menu' })}
        icon={<ChevronRightIcon size={18} aria-hidden="true" />}
        className="kvm-touch-target flex size-[26px] items-center justify-center p-0 text-neutral-400 hover:text-white"
        onClick={() => toggleMenu(true)}
      />
    </div>
  );
};
