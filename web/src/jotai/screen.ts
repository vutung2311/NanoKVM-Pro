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
export const viewportZoomAtom = atom<ViewportZoomState>({
  scale: 1,
  x: 0,
  y: 0
});
