import { Button } from 'antd';
import { useAtomValue, useSetAtom } from 'jotai';
import { useTranslation } from 'react-i18next';

import { viewportZoomAtom, zoomBadgeAtom } from '@/jotai/screen.ts';

// Own component so a pinch only re-renders this button (when the shown factor changes),
// not the whole menu bar.
export const ZoomResetButton = () => {
  const { t } = useTranslation();
  const zoomBadge = useAtomValue(zoomBadgeAtom);
  const setZoom = useSetAtom(viewportZoomAtom);

  if (zoomBadge === null) {
    return null;
  }

  return (
    <Button
      size="small"
      color="primary"
      variant="filled"
      aria-label={t('screen.resetZoom', { defaultValue: 'Reset zoom' })}
      onClick={() => setZoom({ scale: 1, x: 0, y: 0 })}
      className="kvm-touch-target ml-1.5 flex h-[26px] shrink-0 items-center justify-center px-2 text-[11px] font-medium"
    >
      {zoomBadge}×
    </Button>
  );
};
