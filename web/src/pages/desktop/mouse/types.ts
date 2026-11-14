import type { MouseButtonSource } from '@/lib/mouse.ts';

interface MouseMoveAbsoluteEvent {
  type: 'move';
  x: number;
  y: number;
}

interface MouseMoveRelativeEvent {
  type: 'move';
  deltaX: number;
  deltaY: number;
}

interface MouseButtonEvent {
  type: 'mousedown' | 'mouseup';
  button: number;
  source?: MouseButtonSource;
}

interface MouseWheelEvent {
  type: 'wheel';
  deltaY: number;
  deltaX?: number;
}

export type MouseAbsoluteEvent = MouseMoveAbsoluteEvent | MouseButtonEvent | MouseWheelEvent;

export type MouseRelativeEvent = MouseMoveRelativeEvent | MouseButtonEvent | MouseWheelEvent;
