import { useEffect, useRef } from 'react';
import { useAtom, useAtomValue } from 'jotai';

import { videoModeAtom, viewportZoomAtom } from '@/jotai/screen.ts';

import { H264Direct } from './h264-direct.tsx';
import { H264Webrtc } from './h264-webrtc.tsx';
import { H265Direct } from './h265-direct.tsx';
import { H265Webrtc } from './h265-webrtc.tsx';
import { Mjpeg } from './mjpeg.tsx';

export const Screen = () => {
  const videoMode = useAtomValue(videoModeAtom);
  const [zoom, setZoom] = useAtom(viewportZoomAtom);
  const viewportRef = useRef<HTMLDivElement | null>(null);

  // Re-clamp pan offsets if orientation or visual viewport dimensions change while zoomed in
  useEffect(() => {
    const el = viewportRef.current;
    if (!el) return;

    const reclamp = () => {
      const rect = el.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;

      setZoom((prev) => {
        if (prev.scale <= 1.02) {
          return prev.scale === 1 && prev.x === 0 && prev.y === 0
            ? prev
            : { scale: 1, x: 0, y: 0 };
        }
        const maxPanX = (rect.width * (prev.scale - 1)) / 2;
        const maxPanY = (rect.height * (prev.scale - 1)) / 2;
        const nextX = Math.max(-maxPanX, Math.min(maxPanX, prev.x));
        const nextY = Math.max(-maxPanY, Math.min(maxPanY, prev.y));
        if (nextX === prev.x && nextY === prev.y) {
          return prev;
        }
        return { scale: prev.scale, x: nextX, y: nextY };
      });
    };

    const observer = new ResizeObserver(reclamp);
    observer.observe(el);
    return () => observer.disconnect();
  }, [setZoom]);

  const renderContent = () => {
    if (videoMode === 'mjpeg') {
      return <Mjpeg />;
    }

    if (videoMode === 'h264-direct') {
      return <H264Direct />;
    }

    if (videoMode === 'h265-webrtc') {
      return <H265Webrtc />;
    }

    if (videoMode === 'h265-direct') {
      return <H265Direct />;
    }

    return <H264Webrtc />;
  };

  const isZoomed = zoom.scale > 1.001 || zoom.x !== 0 || zoom.y !== 0;

  return (
    <div
      id="screen-viewport"
      ref={viewportRef}
      className="relative w-dvw touch-none overflow-hidden"
      style={{ height: 'var(--visual-vh, 100dvh)' }}
    >
      <div
        className="h-full w-full"
        style={
          isZoomed
            ? {
                transform: `translate3d(${zoom.x}px, ${zoom.y}px, 0) scale(${zoom.scale})`,
                transformOrigin: 'center center'
              }
            : undefined
        }
      >
        {renderContent()}
      </div>
    </div>
  );
};
