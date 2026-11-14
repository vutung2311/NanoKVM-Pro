import { useEffect, useState } from 'react';

import { detectTouchDevice } from '@/lib/touch-device.ts';

export function useTouchDevice(): boolean {
  const [isTouchDevice, setIsTouchDevice] = useState<boolean>(detectTouchDevice);

  useEffect(() => {
    const mediaQuery = window.matchMedia('(pointer: coarse)');
    const update = () => {
      setIsTouchDevice(detectTouchDevice());
    };

    update();
    mediaQuery.addEventListener('change', update);
    window.addEventListener('resize', update);

    return () => {
      mediaQuery.removeEventListener('change', update);
      window.removeEventListener('resize', update);
    };
  }, []);

  return isTouchDevice;
}
