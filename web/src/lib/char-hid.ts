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

// Typographic characters that iOS/Android "smart punctuation" substitutes for ASCII. Without
// this they have no HID mapping and silently vanish (don't -> dont).
const TYPOGRAPHIC_TO_ASCII: Record<string, string> = {
  '\u2018': "'", // ‘
  '\u2019': "'", // ’
  '\u201A': "'", // ‚
  '\u201B': "'", // ‛
  '\u2032': "'", // ′
  '\u201C': '"', // “
  '\u201D': '"', // ”
  '\u201E': '"', // „
  '\u201F': '"', // ‟
  '\u2033': '"', // ″
  '\u2010': '-', // ‐
  '\u2011': '-', // ‑
  '\u2012': '-', // ‒
  '\u2013': '-', // –
  '\u2014': '-', // —
  '\u2212': '-', // −
  '\u2026': '...', // …
  '\u00A0': ' ', // no-break space
  '\u202F': ' ', // narrow no-break space
  '\u2009': ' ' // thin space
};

function sendRawKeyboardReport(modifier: number, keycode: number): boolean {
  const packet = new Uint8Array([MessageEvent.Keyboard, modifier, 0, keycode, 0, 0, 0, 0, 0]);
  return client.send(packet);
}

const STEP_DELAY_MS = 12;

interface QueuedTap {
  modifier: number;
  code: number;
}

class HidTapQueue {
  private queue: QueuedTap[] = [];
  private processing = false;
  // Bumped by clear(): an in-flight tap from an older generation stops sending.
  private generation = 0;

  enqueue(modifier: number, code: number) {
    this.queue.push({ modifier, code });
    if (!this.processing) {
      void this.drain();
    }
  }

  get pending() {
    return this.queue.length;
  }

  clear() {
    this.queue = [];
    this.generation++;
    sendRawKeyboardReport(0, 0);
  }

  private async drain() {
    this.processing = true;
    try {
      while (this.queue.length > 0) {
        const gen = this.generation;
        const next = this.queue.shift()!;
        // Any failed send means the socket is gone or not writable: drop the rest instead of
        // losing characters now and resuming mid-string after a reconnect.
        const send = (modifier: number, code: number) =>
          gen === this.generation && sendRawKeyboardReport(modifier, code);

        let ok = true;
        if (next.modifier !== 0) {
          ok = send(next.modifier, 0);
          if (ok) await sleep(STEP_DELAY_MS);
        }
        if (ok) ok = send(next.modifier, next.code);
        if (ok) await sleep(STEP_DELAY_MS);
        if (ok && next.modifier !== 0) {
          ok = send(next.modifier, 0);
          if (ok) await sleep(8);
        }
        if (ok) ok = send(0, 0);

        if (!ok) {
          if (gen === this.generation) this.clear();
          continue;
        }
        if (this.queue.length > 0) {
          await sleep(STEP_DELAY_MS);
        }
      }
    } finally {
      this.processing = false;
    }
  }
}

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

export const hidTapQueue = new HidTapQueue();

// A dropped connection must not keep typing into the next one.
client.onClose(() => hidTapQueue.clear());

// Longest insert typed in one go (~40 ms per character, so about 80 s).
export const MAX_HID_TEXT_CHARS = 2000;

type ResolvedChar =
  | { kind: 'exact'; entries: HidCharEntry[] }
  | { kind: 'approximate'; entries: HidCharEntry[]; sent: string }
  | { kind: 'dropped' };

function resolveChar(ch: string): ResolvedChar {
  const exact = CHAR_TO_HID[ch];
  if (exact) {
    return { kind: 'exact', entries: [exact] };
  }

  const ascii = TYPOGRAPHIC_TO_ASCII[ch];
  if (ascii) {
    return { kind: 'exact', entries: Array.from(ascii).map((c) => CHAR_TO_HID[c]) };
  }

  // Fall back to the base ASCII letter if a mobile IME (e.g. Telex/accented keyboard) composed a
  // diacritic. The host gets a different character, so callers must surface this.
  const base = ch === 'đ' ? 'd' : ch === 'Đ' ? 'D' : ch.normalize('NFD')[0];
  const baseEntry = base ? CHAR_TO_HID[base] : undefined;
  if (baseEntry) {
    return { kind: 'approximate', entries: [baseEntry], sent: base };
  }

  return { kind: 'dropped' };
}

// Number of HID taps the character produces on the host (0 when it can't be typed).
export function countHidTaps(ch: string): number {
  const resolved = resolveChar(ch);
  return resolved.kind === 'dropped' ? 0 : resolved.entries.length;
}

export function enqueueHidKeyTap(codeName: string, extraModifier = 0) {
  const code = KeycodeMap[codeName];
  if (code === undefined) return;
  hidTapQueue.enqueue(extraModifier, code);
}

export interface HidTextResult {
  // At least one key was typed (so a one-shot modifier was consumed).
  typed: boolean;
  // Characters typed as something else, e.g. 'é' -> 'e'.
  approximated: { from: string; to: string }[];
  // Characters with no key on a US layout; nothing was typed for them.
  dropped: string[];
  // Characters cut off past MAX_HID_TEXT_CHARS.
  truncated: number;
}

// Types text as US-QWERTY key taps. `oneShotModifier` applies to the first key only;
// `lockedModifier` applies to every key.
export function enqueueHidText(
  text: string,
  oneShotModifier = 0,
  lockedModifier = 0
): HidTextResult {
  const result: HidTextResult = { typed: false, approximated: [], dropped: [], truncated: 0 };
  let chars = Array.from(text);
  if (chars.length > MAX_HID_TEXT_CHARS) {
    result.truncated = chars.length - MAX_HID_TEXT_CHARS;
    chars = chars.slice(0, MAX_HID_TEXT_CHARS);
  }

  for (const ch of chars) {
    const resolved = resolveChar(ch);
    if (resolved.kind === 'dropped') {
      result.dropped.push(ch);
      continue;
    }
    if (resolved.kind === 'approximate') {
      result.approximated.push({ from: ch, to: resolved.sent });
    }

    for (const entry of resolved.entries) {
      const extra = lockedModifier | (!result.typed ? oneShotModifier : 0);
      result.typed = true;
      hidTapQueue.enqueue(entry.modifier | extra, entry.code);
    }
  }
  return result;
}
