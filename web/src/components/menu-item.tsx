import { ReactNode, useState } from 'react';
import { Button, Popover, Tooltip } from 'antd';
import clsx from 'clsx';
import { useSetAtom } from 'jotai';
import { useMediaQuery } from 'react-responsive';

import { submenuOpenCountAtom } from '@/jotai/settings.ts';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

type MenuItemProps = {
  title: string;
  icon: ReactNode;
  content: ReactNode;
  className?: string;
  fresh?: boolean;
  onOpenChange?: (open: boolean) => void;
};

export const MenuItem = ({
  title,
  icon,
  content,
  className,
  fresh,
  onOpenChange
}: MenuItemProps) => {
  const isBigScreen = useMediaQuery({ minWidth: 640 });
  const isTouchDevice = useTouchDevice();
  const setSubmenuOpenCount = useSetAtom(submenuOpenCountAtom);

  const [isPopoverOpen, setIsPopoverOpen] = useState(false);
  const [isTooltipOpen, setIsTooltipOpen] = useState(false);

  function togglePopover(open: boolean) {
    setIsTooltipOpen(false);
    setIsPopoverOpen(open);

    // Update global submenu count
    setSubmenuOpenCount((count) => (open ? count + 1 : Math.max(0, count - 1)));

    if (onOpenChange) {
      onOpenChange(open);
    }
  }

  function toggleTooltip(open: boolean) {
    if (isTouchDevice || isPopoverOpen) {
      return;
    }
    setIsTooltipOpen(open);
  }

  const triggerButton = (
    <Button
      type="text"
      size="small"
      aria-label={title}
      icon={icon}
      className={clsx(
        'kvm-touch-target flex h-[30px] w-[30px] shrink-0 items-center justify-center p-0 text-neutral-300 hover:text-white',
        className
      )}
    />
  );

  return (
    <Popover
      content={content}
      arrow={false}
      trigger="click"
      zIndex={900}
      placement={isBigScreen ? 'bottomLeft' : 'bottom'}
      overlayStyle={{ maxWidth: 'calc(100dvw - 16px)' }}
      open={isPopoverOpen}
      onOpenChange={togglePopover}
      fresh={!!fresh}
    >
      {isTouchDevice ? (
        triggerButton
      ) : (
        <Tooltip
          title={title}
          mouseEnterDelay={0.6}
          placement="bottom"
          open={isTooltipOpen}
          onOpenChange={toggleTooltip}
        >
          {triggerButton}
        </Tooltip>
      )}
    </Popover>
  );
};
