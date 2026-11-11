import { useEffect, useState } from 'react';

export interface VisualViewportMetrics {
  width: number;
  height: number;
  offsetTop: number;
  bottomInset: number;
  isKeyboardLikelyOpen: boolean;
}

function readViewportMetrics(): VisualViewportMetrics {
  if (typeof window === 'undefined') {
    return {
      width: 0,
      height: 0,
      offsetTop: 0,
      bottomInset: 0,
      isKeyboardLikelyOpen: false
    };
  }

  const vv = window.visualViewport;
  const innerWidth = window.innerWidth;
  const innerHeight = window.innerHeight;

  if (!vv) {
    return {
      width: innerWidth,
      height: innerHeight,
      offsetTop: 0,
      bottomInset: 0,
      isKeyboardLikelyOpen: false
    };
  }

  // Unified formula across iOS Safari (fixed layout viewport) and Android Chrome (resizes-content):
  // bottomInset is how far above the layout viewport bottom the visual viewport actually ends.
  const bottomInset = Math.max(0, Math.round(innerHeight - (vv.offsetTop + vv.height)));
  const heightShrink = window.screen.height > 0 ? window.screen.height - vv.height : bottomInset;

  return {
    width: Math.round(vv.width),
    height: Math.round(vv.height),
    offsetTop: Math.round(vv.offsetTop),
    bottomInset,
    isKeyboardLikelyOpen: bottomInset > 100 || heightShrink > 240
  };
}

export function useVisualViewport(): VisualViewportMetrics {
  const [metrics, setMetrics] = useState<VisualViewportMetrics>(readViewportMetrics);

  useEffect(() => {
    const vv = window.visualViewport;

    const syncMetrics = () => {
      const next = readViewportMetrics();
      document.documentElement.style.setProperty('--visual-vh', `${next.height}px`);
      setMetrics((prev) => {
        if (
          prev.width === next.width &&
          prev.height === next.height &&
          prev.offsetTop === next.offsetTop &&
          prev.bottomInset === next.bottomInset &&
          prev.isKeyboardLikelyOpen === next.isKeyboardLikelyOpen
        ) {
          return prev;
        }
        return next;
      });
    };

    syncMetrics();

    window.addEventListener('resize', syncMetrics);
    vv?.addEventListener('resize', syncMetrics);
    vv?.addEventListener('scroll', syncMetrics);

    return () => {
      window.removeEventListener('resize', syncMetrics);
      vv?.removeEventListener('resize', syncMetrics);
      vv?.removeEventListener('scroll', syncMetrics);
    };
  }, []);

  return metrics;
}
