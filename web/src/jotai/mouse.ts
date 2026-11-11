import { atom } from 'jotai';

// mouse cursor style
export const mouseStyleAtom = atom('cursor-default');

// mouse mode: absolute or relative
export const mouseModeAtom = atom('absolute');

// mouse scroll direction: -1 or 1
export const scrollDirectionAtom = atom(-1);

export type TouchControlMode = 'trackpad' | 'direct';

// mouse scroll interval (unit: ms)
export const scrollIntervalAtom = atom(0);

// mobile touch control mode: virtual trackpad vs direct touch
export const touchModeAtom = atom<TouchControlMode>('trackpad');

// whether to show floating mouse buttons (L / M / R / Drag Lock) on mobile
export const showMobileMouseButtonsAtom = atom(false);

// virtual cursor overlay position (normalized 0..1 inside rendered media area) for trackpad feedback
export const virtualCursorAtom = atom({
  x: 0.5,
  y: 0.5,
  visible: false
});
