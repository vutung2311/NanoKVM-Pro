import type { CSSProperties } from 'react';

import { VideoRotation } from '@/types';

export function isQuarterTurn(rotation: VideoRotation) {
  return rotation === 90 || rotation === 270;
}

export function getScreenElement() {
  const screen = document.getElementById('screen');
  return screen?.querySelector('img') ?? screen;
}

export function getVideoRotationStyle(scale: number, rotation: VideoRotation): CSSProperties {
  return {
    transform: `scale(${scale}) rotate(${rotation}deg)`,
    transformOrigin: 'center'
  };
}

export function getVideoSizeStyle(rotation: VideoRotation): CSSProperties {
  const quarterTurn = isQuarterTurn(rotation);

  return {
    minWidth: quarterTurn ? 'min(50dvw, var(--visual-vh, 100dvh))' : undefined,
    minHeight: quarterTurn ? 'min(50dvh, 100dvw)' : undefined,
    maxWidth: quarterTurn ? 'var(--visual-vh, 100dvh)' : '100dvw',
    maxHeight: quarterTurn ? '100dvw' : 'var(--visual-vh, 100dvh)'
  };
}

export function getVideoTransformStyle(scale: number, rotation: VideoRotation): CSSProperties {
  return {
    ...getVideoRotationStyle(scale, rotation),
    ...getVideoSizeStyle(rotation)
  };
}

export function inverseRotatePoint(x: number, y: number, rotation: VideoRotation) {
  switch (rotation) {
    case 90:
      return { x: y, y: 1 - x };
    case 180:
      return { x: 1 - x, y: 1 - y };
    case 270:
      return { x: 1 - y, y: x };
    default:
      return { x, y };
  }
}

export function inverseRotateDelta(x: number, y: number, rotation: VideoRotation) {
  switch (rotation) {
    case 90:
      return { x: y, y: -x };
    case 180:
      return { x: -x, y: -y };
    case 270:
      return { x: -y, y: x };
    default:
      return { x, y };
  }
}

export function rotatePoint(x: number, y: number, rotation: VideoRotation) {
  switch (rotation) {
    case 90:
      return { x: 1 - y, y: x };
    case 180:
      return { x: 1 - x, y: 1 - y };
    case 270:
      return { x: y, y: 1 - x };
    default:
      return { x, y };
  }
}

export function getMediaElementSize(screen: Element): { width: number; height: number } | null {
  if (screen instanceof HTMLVideoElement && screen.videoWidth > 0 && screen.videoHeight > 0) {
    return { width: screen.videoWidth, height: screen.videoHeight };
  }

  if (screen instanceof HTMLImageElement && screen.naturalWidth > 0 && screen.naturalHeight > 0) {
    return { width: screen.naturalWidth, height: screen.naturalHeight };
  }

  if (screen instanceof HTMLCanvasElement && screen.width > 0 && screen.height > 0) {
    return { width: screen.width, height: screen.height };
  }

  return null;
}

export interface RenderedMediaBox {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function getRenderedMediaBox(screen: Element, rotation: VideoRotation): RenderedMediaBox {
  const rect = screen.getBoundingClientRect();
  const mediaSize = getMediaElementSize(screen);

  if (!mediaSize || rect.width <= 0 || rect.height <= 0) {
    return {
      left: rect.left,
      top: rect.top,
      width: Math.max(1, rect.width),
      height: Math.max(1, rect.height)
    };
  }

  const rotatedMediaSize = isQuarterTurn(rotation)
    ? { width: mediaSize.height, height: mediaSize.width }
    : mediaSize;
  const videoRatio = rotatedMediaSize.width / rotatedMediaSize.height;
  const elementRatio = rect.width / rect.height;

  let renderedWidth = rect.width;
  let renderedHeight = rect.height;
  let offsetX = 0;
  let offsetY = 0;

  if (videoRatio > elementRatio) {
    renderedHeight = rect.width / videoRatio;
    offsetY = (rect.height - renderedHeight) / 2;
  } else {
    renderedWidth = rect.height * videoRatio;
    offsetX = (rect.width - renderedWidth) / 2;
  }

  return {
    left: rect.left + offsetX,
    top: rect.top + offsetY,
    width: Math.max(1, renderedWidth),
    height: Math.max(1, renderedHeight)
  };
}
