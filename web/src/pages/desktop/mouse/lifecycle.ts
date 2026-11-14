import { client, MessageEvent } from '@/lib/websocket.ts';

/**
 * Coordinates mouse state across mode components and WebSocket reconnects.
 * Reports queued here outlive an Absolute/Relative component unmount.
 */
type ReleaseHandler = () => void;
type ButtonActionHandler = (type: 'mousedown' | 'mouseup', button: number) => void;
export type MouseInterface = 'absolute' | 'relative';

let releaseHandler: ReleaseHandler | null = null;
let buttonActionHandler: ButtonActionHandler | null = null;
// Each HID interface needs its own neutral report because report length selects hidg1/hidg2.
const pendingReleases = new Map<MouseInterface, Uint8Array>();

function buildMouseMessage(report: Uint8Array): Uint8Array {
  const msg = new Uint8Array(1 + report.length);
  msg[0] = MessageEvent.Mouse;
  msg.set(report, 1);
  return msg;
}

function flushPendingMouseReleases(): boolean {
  // A stale release must reach the host before any input from a new mode/connection.
  for (const [mouseInterface, data] of pendingReleases) {
    if (client.send(data)) {
      pendingReleases.delete(mouseInterface);
    }
  }

  return pendingReleases.size === 0;
}

export function initializeMouseInputLifecycle(): () => void {
  // Unexpected close clears local button state; open retries the matching HID releases first.
  const removeOpenHandler = client.onOpen(flushPendingMouseReleases);
  const removeCloseHandler = client.onClose(releaseMouseInput);

  return () => {
    removeOpenHandler();
    removeCloseHandler();
  };
}

export function sendMouseReport(mouseInterface: MouseInterface, report: Uint8Array): boolean {
  // Do not let a new press overtake a neutral report left behind by a broken connection.
  if (!flushPendingMouseReleases()) {
    return false;
  }

  const sent = client.send(buildMouseMessage(report));
  if (sent && report[0] === 0) {
    pendingReleases.delete(mouseInterface);
  }

  return sent;
}

export function sendMouseRelease(mouseInterface: MouseInterface, report: Uint8Array): void {
  const data = buildMouseMessage(report);
  // Record first, then remove only after send accepted the complete neutral report.
  pendingReleases.set(mouseInterface, data);

  if (client.send(data)) {
    pendingReleases.delete(mouseInterface);
  }
}

export function registerMouseReleaseHandler(handler: ReleaseHandler): () => void {
  // Only the mounted mouse mode owns the current local button/touch state.
  releaseHandler = handler;

  return () => {
    if (releaseHandler === handler) {
      releaseHandler = null;
    }
  };
}

export function releaseMouseInput(): void {
  releaseHandler?.();
}

export function registerMouseButtonHandler(handler: ButtonActionHandler): () => void {
  buttonActionHandler = handler;

  return () => {
    if (buttonActionHandler === handler) {
      buttonActionHandler = null;
    }
  };
}

export function triggerMouseButtonAction(type: 'mousedown' | 'mouseup', button: number): void {
  buttonActionHandler?.(type, button);
}

type ButtonsReleasedListener = () => void;
const buttonsReleasedListeners = new Set<ButtonsReleasedListener>();

/**
 * Fired when the active mouse mode force-releases every button (blur, hidden tab,
 * websocket close, failed send, mode switch). UI that shows a held/locked button
 * (drag lock, on-screen L/M/R) must drop that state so it matches the host.
 */
export function onMouseButtonsReleased(listener: ButtonsReleasedListener): () => void {
  buttonsReleasedListeners.add(listener);
  return () => {
    buttonsReleasedListeners.delete(listener);
  };
}

export function notifyMouseButtonsReleased(): void {
  for (const listener of buttonsReleasedListeners) {
    listener();
  }
}

// Browsers synthesize mousedown/mousemove/mouseup after a tap on any element whose
// touch events were not cancelled (menu buttons, drag-lock toggle). Those must not
// reach the host as real mouse input.
const TOUCH_EMULATION_WINDOW_MS = 1000;
let lastTouchTimestamp = -Infinity;
let touchTrackerRefs = 0;

function recordTouch() {
  lastTouchTimestamp = performance.now();
}

export function trackTouchActivity(): () => void {
  if (touchTrackerRefs++ === 0) {
    const opts = { capture: true, passive: true } as const;
    window.addEventListener('touchstart', recordTouch, opts);
    window.addEventListener('touchend', recordTouch, opts);
    window.addEventListener('touchcancel', recordTouch, opts);
  }
  return () => {
    if (--touchTrackerRefs === 0) {
      window.removeEventListener('touchstart', recordTouch, true);
      window.removeEventListener('touchend', recordTouch, true);
      window.removeEventListener('touchcancel', recordTouch, true);
    }
  };
}

export function isTouchEmulatedMouseEvent(e: MouseEvent): boolean {
  const caps = (e as MouseEvent & { sourceCapabilities?: { firesTouchEvents?: boolean } })
    .sourceCapabilities;
  if (caps && caps.firesTouchEvents) return true;
  return performance.now() - lastTouchTimestamp < TOUCH_EMULATION_WINDOW_MS;
}
