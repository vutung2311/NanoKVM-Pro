import { useEffect, useRef, useState } from 'react';
import clsx from 'clsx';
import { useAtomValue, useSetAtom, useStore } from 'jotai';

import {
  videoModeAtom,
  videoParametersAtom,
  viewportZoomAtom,
  ViewportZoomState
} from '@/jotai/screen.ts';

import { H264Direct } from './h264-direct.tsx';
import { H264Webrtc } from './h264-webrtc.tsx';
import { H265Direct } from './h265-direct.tsx';
import { H265Webrtc } from './h265-webrtc.tsx';
import { Mjpeg } from './mjpeg.tsx';

export const Screen = () => {
  const videoMode = useAtomValue(videoModeAtom);
  const videoScale = useAtomValue(videoParametersAtom).scale;
  // Pinch/pan writes the zoom atom on every touchmove. Apply it straight to the DOM instead
  // of re-rendering (and re-reconciling the video element) at 60-120 Hz.
  const store = useStore();
  const setZoom = useSetAtom(viewportZoomAtom);
  const [isZoomed, setIsZoomed] = useState(() => isZoomActive(store.get(viewportZoomAtom)));
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const apply = () => {
      const zoom = store.get(viewportZoomAtom);
      const zoomed = isZoomActive(zoom);
      const el = contentRef.current;
      if (el) {
        el.style.transform = zoomed
          ? `translate3d(${zoom.x}px, ${zoom.y}px, 0) scale(${zoom.scale})`
          : '';
        el.style.transformOrigin = zoomed ? 'center center' : '';
      }
      setIsZoomed(zoomed);
    };
    apply();
    return store.sub(viewportZoomAtom, apply);
  }, [store]);

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

  // Scale > 1x (video settings) enlarges the video past the viewport; let it scroll like
  // upstream did. Touch pinch-zoom pans with its own transform, so keep it clipped then.
  const canScroll = videoScale > 1 && !isZoomed;

  return (
    <div
      id="screen-viewport"
      ref={viewportRef}
      className={clsx('relative w-dvw touch-none', canScroll ? 'overflow-auto' : 'overflow-hidden')}
      style={{ height: 'var(--visual-vh, 100dvh)' }}
    >
      <div ref={contentRef} className="h-full w-full">
        {renderContent()}
      </div>
    </div>
  );
};

function isZoomActive(zoom: ViewportZoomState) {
  return zoom.scale > 1.001 || zoom.x !== 0 || zoom.y !== 0;
}
