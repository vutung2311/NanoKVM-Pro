import { useEffect, useState } from 'react';
import { Button, Tooltip } from 'antd';
import { MaximizeIcon, MinimizeIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

export const Fullscreen = () => {
  const { t } = useTranslation();

  const [isFullscreen, setIsFullscreen] = useState(false);

  useEffect(() => {
    const onFullscreenChange = () => {
      setIsFullscreen(!!document.fullscreenElement);
    };

    onFullscreenChange();

    document.addEventListener('fullscreenchange', onFullscreenChange);

    return () => {
      document.removeEventListener('fullscreenchange', onFullscreenChange);
    };
  }, []);

  function handleFullscreen() {
    if (!document.fullscreenElement) {
      const element = document.documentElement;
      element.requestFullscreen();

      // @ts-expect-error - https://developer.mozilla.org/en-US/docs/Web/API/Keyboard/lock
      navigator.keyboard?.lock();
    } else {
      document.exitFullscreen();

      // @ts-expect-error - https://developer.mozilla.org/en-US/docs/Web/API/Keyboard/unlock
      navigator.keyboard?.unlock();
    }
  }

  return (
    <div className="hidden sm:flex">
      <Tooltip title={t('fullscreen.toggle')} placement="bottom" mouseEnterDelay={0.6}>
        <Button
          type="text"
          size="small"
          aria-label={t('fullscreen.toggle')}
          icon={
            isFullscreen ? (
              <MinimizeIcon size={18} aria-hidden="true" />
            ) : (
              <MaximizeIcon size={18} aria-hidden="true" />
            )
          }
          className="flex h-[30px] w-[30px] items-center justify-center p-0 text-neutral-300 hover:text-white"
          onClick={handleFullscreen}
        />
      </Tooltip>
    </div>
  );
};
