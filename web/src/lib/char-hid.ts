import { KeycodeMap, ModifierBits } from './keymap';
import { client, MessageEvent } from './websocket';

interface HidCharEntry {
  modifier: number;
  code: number;
}

const S = ModifierBits.LeftShift;

// Maps printable ASCII + whitespace onto US QWERTY USB HID (modifier, keycode)
export const CHAR_TO_HID: Record<string, HidCharEntry> = {
  a: { modifier: 0, code: KeycodeMap.KeyA },
  b: { modifier: 0, code: KeycodeMap.KeyB },
  c: { modifier: 0, code: KeycodeMap.KeyC },
  d: { modifier: 0, code: KeycodeMap.KeyD },
  e: { modifier: 0, code: KeycodeMap.KeyE },
  f: { modifier: 0, code: KeycodeMap.KeyF },
  g: { modifier: 0, code: KeycodeMap.KeyG },
  h: { modifier: 0, code: KeycodeMap.KeyH },
  i: { modifier: 0, code: KeycodeMap.KeyI },
  j: { modifier: 0, code: KeycodeMap.KeyJ },
  k: { modifier: 0, code: KeycodeMap.KeyK },
  l: { modifier: 0, code: KeycodeMap.KeyL },
  m: { modifier: 0, code: KeycodeMap.KeyM },
  n: { modifier: 0, code: KeycodeMap.KeyN },
  o: { modifier: 0, code: KeycodeMap.KeyO },
  p: { modifier: 0, code: KeycodeMap.KeyP },
  q: { modifier: 0, code: KeycodeMap.KeyQ },
  r: { modifier: 0, code: KeycodeMap.KeyR },
  s: { modifier: 0, code: KeycodeMap.KeyS },
  t: { modifier: 0, code: KeycodeMap.KeyT },
  u: { modifier: 0, code: KeycodeMap.KeyU },
  v: { modifier: 0, code: KeycodeMap.KeyV },
  w: { modifier: 0, code: KeycodeMap.KeyW },
  x: { modifier: 0, code: KeycodeMap.KeyX },
  y: { modifier: 0, code: KeycodeMap.KeyY },
  z: { modifier: 0, code: KeycodeMap.KeyZ },

  A: { modifier: S, code: KeycodeMap.KeyA },
  B: { modifier: S, code: KeycodeMap.KeyB },
  C: { modifier: S, code: KeycodeMap.KeyC },
  D: { modifier: S, code: KeycodeMap.KeyD },
  E: { modifier: S, code: KeycodeMap.KeyE },
  F: { modifier: S, code: KeycodeMap.KeyF },
  G: { modifier: S, code: KeycodeMap.KeyG },
  H: { modifier: S, code: KeycodeMap.KeyH },
  I: { modifier: S, code: KeycodeMap.KeyI },
  J: { modifier: S, code: KeycodeMap.KeyJ },
  K: { modifier: S, code: KeycodeMap.KeyK },
  L: { modifier: S, code: KeycodeMap.KeyL },
  M: { modifier: S, code: KeycodeMap.KeyM },
  N: { modifier: S, code: KeycodeMap.KeyN },
  O: { modifier: S, code: KeycodeMap.KeyO },
  P: { modifier: S, code: KeycodeMap.KeyP },
  Q: { modifier: S, code: KeycodeMap.KeyQ },
  R: { modifier: S, code: KeycodeMap.KeyR },
  S: { modifier: S, code: KeycodeMap.KeyS },
  T: { modifier: S, code: KeycodeMap.KeyT },
  U: { modifier: S, code: KeycodeMap.KeyU },
  V: { modifier: S, code: KeycodeMap.KeyV },
  W: { modifier: S, code: KeycodeMap.KeyW },
  X: { modifier: S, code: KeycodeMap.KeyX },
  Y: { modifier: S, code: KeycodeMap.KeyY },
  Z: { modifier: S, code: KeycodeMap.KeyZ },

  '1': { modifier: 0, code: KeycodeMap.Digit1 },
  '2': { modifier: 0, code: KeycodeMap.Digit2 },
  '3': { modifier: 0, code: KeycodeMap.Digit3 },
  '4': { modifier: 0, code: KeycodeMap.Digit4 },
  '5': { modifier: 0, code: KeycodeMap.Digit5 },
  '6': { modifier: 0, code: KeycodeMap.Digit6 },
  '7': { modifier: 0, code: KeycodeMap.Digit7 },
  '8': { modifier: 0, code: KeycodeMap.Digit8 },
  '9': { modifier: 0, code: KeycodeMap.Digit9 },
  '0': { modifier: 0, code: KeycodeMap.Digit0 },

  '!': { modifier: S, code: KeycodeMap.Digit1 },
  '@': { modifier: S, code: KeycodeMap.Digit2 },
  '#': { modifier: S, code: KeycodeMap.Digit3 },
  $: { modifier: S, code: KeycodeMap.Digit4 },
  '%': { modifier: S, code: KeycodeMap.Digit5 },
  '^': { modifier: S, code: KeycodeMap.Digit6 },
  '&': { modifier: S, code: KeycodeMap.Digit7 },
  '*': { modifier: S, code: KeycodeMap.Digit8 },
  '(': { modifier: S, code: KeycodeMap.Digit9 },
  ')': { modifier: S, code: KeycodeMap.Digit0 },

  '\n': { modifier: 0, code: KeycodeMap.Enter },
  '\r': { modifier: 0, code: KeycodeMap.Enter },
  '\t': { modifier: 0, code: KeycodeMap.Tab },
  ' ': { modifier: 0, code: KeycodeMap.Space },
  '-': { modifier: 0, code: KeycodeMap.Minus },
  '=': { modifier: 0, code: KeycodeMap.Equal },
  '[': { modifier: 0, code: KeycodeMap.BracketLeft },
  ']': { modifier: 0, code: KeycodeMap.BracketRight },
  '\\': { modifier: 0, code: KeycodeMap.Backslash },
  ';': { modifier: 0, code: KeycodeMap.Semicolon },
  "'": { modifier: 0, code: KeycodeMap.Quote },
  '`': { modifier: 0, code: KeycodeMap.Backquote },
  ',': { modifier: 0, code: KeycodeMap.Comma },
  '.': { modifier: 0, code: KeycodeMap.Period },
  '/': { modifier: 0, code: KeycodeMap.Slash },

  _: { modifier: S, code: KeycodeMap.Minus },
  '+': { modifier: S, code: KeycodeMap.Equal },
  '{': { modifier: S, code: KeycodeMap.BracketLeft },
  '}': { modifier: S, code: KeycodeMap.BracketRight },
  '|': { modifier: S, code: KeycodeMap.Backslash },
  ':': { modifier: S, code: KeycodeMap.Semicolon },
  '"': { modifier: S, code: KeycodeMap.Quote },
  '~': { modifier: S, code: KeycodeMap.Backquote },
  '<': { modifier: S, code: KeycodeMap.Comma },
  '>': { modifier: S, code: KeycodeMap.Period },
  '?': { modifier: S, code: KeycodeMap.Slash }
};

function sendRawKeyboardReport(modifier: number, keycode: number) {
  const packet = new Uint8Array([MessageEvent.Keyboard, modifier, 0, keycode, 0, 0, 0, 0, 0]);
  client.send(packet);
}

const STEP_DELAY_MS = 12;

interface QueuedTap {
  modifier: number;
  code: number;
}

class HidTapQueue {
  private queue: QueuedTap[] = [];
  private processing = false;

  enqueue(modifier: number, code: number) {
    this.queue.push({ modifier, code });
    if (!this.processing) {
      void this.drain();
    }
  }

  clear() {
    this.queue = [];
    sendRawKeyboardReport(0, 0);
  }

  private async drain() {
    this.processing = true;
    while (this.queue.length > 0) {
      const next = this.queue.shift()!;
      if (next.modifier !== 0) {
        sendRawKeyboardReport(next.modifier, 0);
        await sleep(STEP_DELAY_MS);
      }
      sendRawKeyboardReport(next.modifier, next.code);
      await sleep(STEP_DELAY_MS);
      if (next.modifier !== 0) {
        sendRawKeyboardReport(next.modifier, 0);
        await sleep(8);
      }
      sendRawKeyboardReport(0, 0);
      if (this.queue.length > 0) {
        await sleep(STEP_DELAY_MS);
      }
    }
    this.processing = false;
  }
}

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

export const hidTapQueue = new HidTapQueue();

export function resolveHidChar(ch: string): HidCharEntry | undefined {
  if (CHAR_TO_HID[ch]) {
    return CHAR_TO_HID[ch];
  }
  if (ch === 'đ') {
    return CHAR_TO_HID.d;
  }
  if (ch === 'Đ') {
    return CHAR_TO_HID.D;
  }
  // Fall back to base ASCII letter if a mobile IME (e.g. Telex/accented keyboard) composed a diacritic
  const base = ch.normalize('NFD')[0];
  return base ? CHAR_TO_HID[base] : undefined;
}

export function enqueueHidKeyTap(codeName: string, extraModifier = 0) {
  const code = KeycodeMap[codeName];
  if (code === undefined) return;
  hidTapQueue.enqueue(extraModifier, code);
}

export function enqueueHidText(text: string, firstCharExtraModifier = 0): boolean {
  let consumedModifier = false;
  for (const ch of Array.from(text)) {
    const entry = resolveHidChar(ch);
    if (!entry) continue;

    const extra = !consumedModifier ? firstCharExtraModifier : 0;
    consumedModifier = true;
    hidTapQueue.enqueue(entry.modifier | extra, entry.code);
  }
  return consumedModifier;
}
