import { useAtomValue } from 'jotai';

import { mouseModeAtom } from '@/jotai/mouse.ts';

import { Absolute } from './absolute.tsx';
import { MobileMouseControls } from './mobile-controls.tsx';
import { Relative } from './relative.tsx';

export const Mouse = () => {
  const mouseMode = useAtomValue(mouseModeAtom);

  return (
    <>
      {mouseMode === 'relative' ? <Relative /> : <Absolute />}
      <MobileMouseControls />
    </>
  );
};
