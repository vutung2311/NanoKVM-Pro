import { useEffect, useState } from 'react';

function detectTouchDevice(): boolean {
  if (typeof window === 'undefined') {
    return false;
  }

  if (window.matchMedia('(pointer: coarse)').matches) {
    return true;
  }

  // Fallback for mobile WebViews that omit pointer media queries
  const hasFinePointer = window.matchMedia('(pointer: fine)').matches;
  return !hasFinePointer && ('ontouchstart' in window || navigator.maxTouchPoints > 0);
}

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
