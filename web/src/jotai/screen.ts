import { atom } from 'jotai';

import { VideoMode, VideoParameters, VideoStatus } from '@/types';

export const videoModeAtom = atom<VideoMode | null>(null);

export const videoParametersAtom = atom<VideoParameters>({
  rateControlMode: 'vbr', // cbr | vbr
  bitrate: 8000, // 1000 - 20000
  gop: 50, // 1 - 200
  fps: 0, // 0 - 120
  scale: 1,
  rotation: 0,
  quality: 80 // 1-100 (only for mjpeg)
});

export const videoStatusAtom = atom<VideoStatus>(VideoStatus.Normal);

export interface ViewportZoomState {
  scale: number;
  x: number;
  y: number;
}

export const videoVolumeAtom = atom(0);

// client-side pinch-to-zoom & pan state on touch devices
// Written on every pinch/pan touchmove: components should not subscribe to it with
// useAtom/useAtomValue. Read it imperatively (store.get / store.sub) or use a derived atom.
export const viewportZoomAtom = atom<ViewportZoomState>({
  scale: 1,
  x: 0,
  y: 0
});

// Zoom factor shown on the reset button (one decimal), or null when not zoomed. A string
// only changes a few times per pinch, so the menu re-renders rarely.
export const zoomBadgeAtom = atom((get) => {
  const { scale } = get(viewportZoomAtom);
  return scale > 1.02 ? scale.toFixed(1) : null;
});
