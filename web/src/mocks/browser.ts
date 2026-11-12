import { http as mswHttp, HttpResponse } from 'msw';
import { setupWorker } from 'msw/browser';

import { existToken, setToken } from '@/lib/cookie.ts';
import { http } from '@/lib/http.ts';
import { KeycodeMap, ModifierBits } from '@/lib/keymap.ts';
import * as storage from '@/lib/localstorage.ts';
import { client, MessageEvent } from '@/lib/websocket.ts';

export const handlers = [
  mswHttp.post('/api/auth/login', () => {
    return HttpResponse.json({
      code: 0,
      data: {
        token: 'mocked_token'
      }
    });
  })
];

export const worker = setupWorker(...handlers);

// Reverse HID keycode -> readable key name for live mock screen readout
const CODE_TO_NAME: Record<number, string> = {};
for (const [name, code] of Object.entries(KeycodeMap)) {
  if (!(code in CODE_TO_NAME)) {
    CODE_TO_NAME[code] = name;
  }
}

const CODE_TO_CHAR: Record<number, [string, string]> = {
  [KeycodeMap.KeyA]: ['a', 'A'],
  [KeycodeMap.KeyB]: ['b', 'B'],
  [KeycodeMap.KeyC]: ['c', 'C'],
  [KeycodeMap.KeyD]: ['d', 'D'],
  [KeycodeMap.KeyE]: ['e', 'E'],
  [KeycodeMap.KeyF]: ['f', 'F'],
  [KeycodeMap.KeyG]: ['g', 'G'],
  [KeycodeMap.KeyH]: ['h', 'H'],
  [KeycodeMap.KeyI]: ['i', 'I'],
  [KeycodeMap.KeyJ]: ['j', 'J'],
  [KeycodeMap.KeyK]: ['k', 'K'],
  [KeycodeMap.KeyL]: ['l', 'L'],
  [KeycodeMap.KeyM]: ['m', 'M'],
  [KeycodeMap.KeyN]: ['n', 'N'],
  [KeycodeMap.KeyO]: ['o', 'O'],
  [KeycodeMap.KeyP]: ['p', 'P'],
  [KeycodeMap.KeyQ]: ['q', 'Q'],
  [KeycodeMap.KeyR]: ['r', 'R'],
  [KeycodeMap.KeyS]: ['s', 'S'],
  [KeycodeMap.KeyT]: ['t', 'T'],
  [KeycodeMap.KeyU]: ['u', 'U'],
  [KeycodeMap.KeyV]: ['v', 'V'],
  [KeycodeMap.KeyW]: ['w', 'W'],
  [KeycodeMap.KeyX]: ['x', 'X'],
  [KeycodeMap.KeyY]: ['y', 'Y'],
  [KeycodeMap.KeyZ]: ['z', 'Z'],
  [KeycodeMap.Digit1]: ['1', '!'],
  [KeycodeMap.Digit2]: ['2', '@'],
  [KeycodeMap.Digit3]: ['3', '#'],
  [KeycodeMap.Digit4]: ['4', '$'],
  [KeycodeMap.Digit5]: ['5', '%'],
  [KeycodeMap.Digit6]: ['6', '^'],
  [KeycodeMap.Digit7]: ['7', '&'],
  [KeycodeMap.Digit8]: ['8', '*'],
  [KeycodeMap.Digit9]: ['9', '('],
  [KeycodeMap.Digit0]: ['0', ')'],
  [KeycodeMap.Space]: [' ', ' '],
  [KeycodeMap.Minus]: ['-', '_'],
  [KeycodeMap.Equal]: ['=', '+'],
  [KeycodeMap.BracketLeft]: ['[', '{'],
  [KeycodeMap.BracketRight]: [']', '}'],
  [KeycodeMap.Backslash]: ['\\', '|'],
  [KeycodeMap.Semicolon]: [';', ':'],
  [KeycodeMap.Quote]: ["'", '"'],
  [KeycodeMap.Backquote]: ['`', '~'],
  [KeycodeMap.Comma]: [',', '<'],
  [KeycodeMap.Period]: ['.', '>'],
  [KeycodeMap.Slash]: ['/', '?']
};

function installMockApiAdapter() {
  const axiosInstance = (http as any).instance;
  if (!axiosInstance) return;

  axiosInstance.defaults.adapter = async (config: any) => {
    const url: string = config.url || '';
    let data: any = {};

    if (url.includes('/api/auth/login')) {
      data = { token: 'mocked_token' };
    } else if (url.includes('/api/vm/info')) {
      data = { ip: [{ name: 'eth0', addr: '192.168.1.88' }], mdns: 'nanokvm-mock.local' };
    } else if (url.includes('/api/vm/menubar')) {
      data = { disabledItems: [] };
    } else if (url.includes('/api/hid/shortcuts')) {
      data = { shortcuts: [] };
    } else if (url.includes('/api/hid/shortcut/leader-key')) {
      data = { key: '' };
    } else if (url.includes('/api/hid/mode')) {
      data = { mode: 'normal' };
    } else if (url.includes('/api/application/version')) {
      data = { current: '1.2.15', latest: '1.2.15' };
    } else if (url.includes('/api/storage/image')) {
      data = { files: [] };
    }

    return {
      data: { code: 0, msg: 'ok', data },
      status: 200,
      statusText: 'OK',
      headers: {},
      config
    };
  };
}

function installMockHidAndScreen() {
  const WIDTH = 1920;
  const HEIGHT = 1080;

  const state = {
    cursorX: WIDTH / 2,
    cursorY: HEIGHT / 2,
    buttons: 0,
    prevButtons: 0,
    wheelTotalY: 0,
    wheelTotalX: 0,
    lastEventLabel: 'Ready — glide, tap, pinch-zoom, or open phone keyboard!',
    typedText: 'root@host:~# ',
    keyHistory: [] as string[],
    prevKeycode: 0,
    dragBox: { x: 1260, y: 200, w: 420, h: 190, dragging: false, offsetX: 0, offsetY: 0 },
    scrollPaneOffset: 0,
    clicks: [] as { x: number; y: number; right: boolean; ts: number }[],
    targetHits: [false, false, false]
  };

  const LOG_LINE_COUNT = 200;
  const VISIBLE_LOG_LINES = 10;
  const logLines = Array.from({ length: LOG_LINE_COUNT }, (_, i) => {
    const n = String(i + 1).padStart(3, '0');
    return `[Line ${n}/200] systemd-journald: mock kernel event #${1000 + i * 7}`;
  });

  const targets = [
    { x: 48, y: 90, w: 170, h: 46, label: 'Tiny Target 1' },
    { x: 1710, y: 90, w: 160, h: 38, label: 'Tiny Close [x]' },
    { x: 48, y: 990, w: 190, h: 46, label: 'Bottom-Left Btn' }
  ];

  const canvas = document.createElement('canvas');
  canvas.width = WIDTH;
  canvas.height = HEIGHT;
  const ctx = canvas.getContext('2d')!;
  let dirty = true;

  function toSignedByte(b: number): number {
    return b > 127 ? b - 256 : b;
  }

  function handleMousePacket(bytes: Uint8Array) {
    state.prevButtons = state.buttons;
    state.buttons = bytes[0];

    if (bytes.length >= 6) {
      // Absolute report (6 or 7 bytes)
      const rawX = bytes[1] | (bytes[2] << 8);
      const rawY = bytes[3] | (bytes[4] << 8);
      state.cursorX = Math.round((rawX / 0x7fff) * WIDTH);
      state.cursorY = Math.round((rawY / 0x7fff) * HEIGHT);
      const wheelY = toSignedByte(bytes[5]);
      const wheelX = bytes.length >= 7 ? toSignedByte(bytes[6]) : 0;
      if (wheelY !== 0 || wheelX !== 0) {
        state.wheelTotalY += wheelY;
        state.wheelTotalX += wheelX;
        // HID wheel > 0 = scroll up (move viewport toward line 1), wheel < 0 = scroll down
        state.scrollPaneOffset = Math.max(
          0,
          Math.min(LOG_LINE_COUNT - VISIBLE_LOG_LINES, state.scrollPaneOffset - wheelY)
        );
        state.lastEventLabel = `Wheel dY=${wheelY} dX=${wheelX} (total Y=${state.wheelTotalY})`;
      }
    } else if (bytes.length >= 4) {
      // Relative report (4 or 5 bytes)
      const dx = toSignedByte(bytes[1]);
      const dy = toSignedByte(bytes[2]);
      state.cursorX = Math.max(0, Math.min(WIDTH, state.cursorX + dx));
      state.cursorY = Math.max(0, Math.min(HEIGHT, state.cursorY + dy));
      const wheelY = toSignedByte(bytes[3]);
      const wheelX = bytes.length >= 5 ? toSignedByte(bytes[4]) : 0;
      if (wheelY !== 0 || wheelX !== 0) {
        state.wheelTotalY += wheelY;
        state.wheelTotalX += wheelX;
        state.scrollPaneOffset = Math.max(
          0,
          Math.min(LOG_LINE_COUNT - VISIBLE_LOG_LINES, state.scrollPaneOffset - wheelY)
        );
        state.lastEventLabel = `Wheel dY=${wheelY} dX=${wheelX} (total Y=${state.wheelTotalY})`;
      }
    }

    const leftJustPressed = (state.buttons & 1) !== 0 && (state.prevButtons & 1) === 0;
    const rightJustPressed = (state.buttons & 2) !== 0 && (state.prevButtons & 2) === 0;
    const midJustPressed = (state.buttons & 4) !== 0 && (state.prevButtons & 4) === 0;

    if (leftJustPressed) {
      state.clicks.push({ x: state.cursorX, y: state.cursorY, right: false, ts: Date.now() });
      state.lastEventLabel = `Left Click @ (${state.cursorX}, ${state.cursorY})`;

      targets.forEach((t, idx) => {
        if (
          state.cursorX >= t.x &&
          state.cursorX <= t.x + t.w &&
          state.cursorY >= t.y &&
          state.cursorY <= t.y + t.h
        ) {
          state.targetHits[idx] = !state.targetHits[idx];
        }
      });

      const b = state.dragBox;
      if (
        state.cursorX >= b.x &&
        state.cursorX <= b.x + b.w &&
        state.cursorY >= b.y &&
        state.cursorY <= b.y + b.h
      ) {
        b.dragging = true;
        b.offsetX = state.cursorX - b.x;
        b.offsetY = state.cursorY - b.y;
      }
    }

    if ((state.buttons & 1) === 0) {
      state.dragBox.dragging = false;
    } else if (state.dragBox.dragging) {
      state.dragBox.x = Math.max(20, Math.min(WIDTH - state.dragBox.w - 20, state.cursorX - state.dragBox.offsetX));
      state.dragBox.y = Math.max(60, Math.min(HEIGHT - state.dragBox.h - 20, state.cursorY - state.dragBox.offsetY));
      state.lastEventLabel = `Dragging window -> (${state.dragBox.x}, ${state.dragBox.y})`;
    }

    if (rightJustPressed) {
      state.clicks.push({ x: state.cursorX, y: state.cursorY, right: true, ts: Date.now() });
      state.lastEventLabel = `Right Click @ (${state.cursorX}, ${state.cursorY})`;
    }

    if (midJustPressed) {
      state.lastEventLabel = `Middle Click @ (${state.cursorX}, ${state.cursorY})`;
    }

    if (state.clicks.length > 10) {
      state.clicks.shift();
    }
    dirty = true;
  }

  function handleKeyboardPacket(bytes: Uint8Array) {
    const mod = bytes[0];
    const code = bytes[2];

    if (code === 0) {
      state.prevKeycode = 0;
      return;
    }
    if (code === state.prevKeycode) {
      return;
    }
    state.prevKeycode = code;

    const mods: string[] = [];
    if (mod & (ModifierBits.LeftCtrl | ModifierBits.RightCtrl)) mods.push('Ctrl');
    if (mod & (ModifierBits.LeftAlt | ModifierBits.RightAlt)) mods.push('Alt');
    if (mod & (ModifierBits.LeftShift | ModifierBits.RightShift)) mods.push('Shift');
    if (mod & (ModifierBits.LeftMeta | ModifierBits.RightMeta)) mods.push('Win');

    const keyName = CODE_TO_NAME[code] || `0x${code.toString(16)}`;
    const combo = [...mods, keyName].join('+');
    state.keyHistory.push(combo);
    if (state.keyHistory.length > 10) {
      state.keyHistory.shift();
    }
    state.lastEventLabel = `HID Key: ${combo}`;

    const hasCtrlOrAltOrMeta =
      (mod &
        (ModifierBits.LeftCtrl |
          ModifierBits.RightCtrl |
          ModifierBits.LeftAlt |
          ModifierBits.RightAlt |
          ModifierBits.LeftMeta |
          ModifierBits.RightMeta)) !==
      0;

    if (!hasCtrlOrAltOrMeta) {
      if (code === KeycodeMap.Backspace) {
        if (state.typedText.length > 0) {
          state.typedText = state.typedText.slice(0, -1);
        }
      } else if (code === KeycodeMap.Enter) {
        state.typedText += '\nroot@host:~# ';
        const lines = state.typedText.split('\n');
        if (lines.length > 7) {
          state.typedText = lines.slice(-7).join('\n');
        }
      } else if (code === KeycodeMap.Tab) {
        state.typedText += '  ';
      } else if (CODE_TO_CHAR[code]) {
        const shifted = (mod & (ModifierBits.LeftShift | ModifierBits.RightShift)) !== 0;
        state.typedText += CODE_TO_CHAR[code][shifted ? 1 : 0];
      }
    } else {
      state.typedText += ` ^[${combo}] `;
    }

    dirty = true;
  }

  // Intercept WsClient so HID reports succeed in mock mode without a backend WebSocket
  let mockConnected = false;
  client.connect = function () {
    mockConnected = true;
  };
  client.close = function () {
    mockConnected = false;
  };
  Object.defineProperty(client, 'isConnected', {
    get: () => mockConnected
  });
  client.send = function (data: any): boolean {
    if (!mockConnected) return false;
    const bytes =
      data instanceof Uint8Array
        ? data
        : data instanceof ArrayBuffer
          ? new Uint8Array(data)
          : new Uint8Array(data);

    if (bytes[0] === MessageEvent.Mouse) {
      handleMousePacket(bytes.subarray(1));
    } else if (bytes[0] === MessageEvent.Keyboard) {
      handleKeyboardPacket(bytes.subarray(1));
    }
    return true;
  };

  function renderMockDesktop() {
    ctx.fillStyle = '#0f172a';
    ctx.fillRect(0, 0, WIDTH, HEIGHT);

    // Subtle 120px coordinate grid
    ctx.strokeStyle = 'rgba(148, 163, 184, 0.12)';
    ctx.lineWidth = 1;
    for (let x = 0; x <= WIDTH; x += 120) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, HEIGHT);
      ctx.stroke();
    }
    for (let y = 0; y <= HEIGHT; y += 120) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(WIDTH, y);
      ctx.stroke();
    }

    // Top status bar on mock host
    ctx.fillStyle = '#1e293b';
    ctx.fillRect(0, 0, WIDTH, 48);
    ctx.fillStyle = '#e2e8f0';
    ctx.font = 'bold 22px monospace';
    ctx.fillText('NanoKVM Mock 1920x1080 Host — Safe Mobile Test Sandbox', 28, 32);

    // Precision test buttons
    targets.forEach((t, idx) => {
      ctx.fillStyle = state.targetHits[idx] ? '#16a34a' : '#334155';
      ctx.fillRect(t.x, t.y, t.w, t.h);
      ctx.strokeStyle = '#94a3b8';
      ctx.lineWidth = 2;
      ctx.strokeRect(t.x, t.y, t.w, t.h);
      ctx.fillStyle = '#f8fafc';
      ctx.font = '18px sans-serif';
      ctx.fillText(`${t.label} ${state.targetHits[idx] ? '✓' : ''}`, t.x + 12, t.y + 29);
    });

    // Draggable test window
    const b = state.dragBox;
    ctx.fillStyle = b.dragging ? '#1d4ed8' : '#1e3a8a';
    ctx.fillRect(b.x, b.y, b.w, b.h);
    ctx.strokeStyle = '#60a5fa';
    ctx.lineWidth = 3;
    ctx.strokeRect(b.x, b.y, b.w, b.h);
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('Drag Me! (Double-tap & slide)', b.x + 24, b.y + 45);
    ctx.font = '18px monospace';
    ctx.fillStyle = '#bfdbfe';
    ctx.fillText(`pos: (${b.x}, ${b.y})`, b.x + 24, b.y + 90);
    ctx.fillText(`scroll Y: ${state.wheelTotalY}  X: ${state.wheelTotalX}`, b.x + 24, b.y + 130);

    // Visual Scrollable Log Pane (60 lines + scrollbar thumb)
    const sp = { x: 1260, y: 420, w: 610, h: 400 };
    ctx.fillStyle = '#090d16';
    ctx.fillRect(sp.x, sp.y, sp.w, sp.h);
    ctx.strokeStyle = '#38bdf8';
    ctx.lineWidth = 2;
    ctx.strokeRect(sp.x, sp.y, sp.w, sp.h);
    ctx.fillStyle = '#0f172a';
    ctx.fillRect(sp.x, sp.y, sp.w, 40);
    ctx.fillStyle = '#7dd3fc';
    ctx.font = 'bold 18px monospace';
    ctx.fillText(
      `Scroll Test Viewer (Lines ${state.scrollPaneOffset + 1}-${state.scrollPaneOffset + VISIBLE_LOG_LINES} of ${LOG_LINE_COUNT})`,
      sp.x + 16,
      sp.y + 26
    );

    ctx.font = '16px monospace';
    for (let i = 0; i < VISIBLE_LOG_LINES; i++) {
      const idx = state.scrollPaneOffset + i;
      const rowY = sp.y + 70 + i * 32;
      if (idx % 2 === 0) {
        ctx.fillStyle = 'rgba(30, 41, 59, 0.45)';
        ctx.fillRect(sp.x + 6, rowY - 20, sp.w - 26, 28);
      }
      ctx.fillStyle = idx === state.scrollPaneOffset ? '#fde047' : '#cbd5e1';
      ctx.fillText(logLines[idx], sp.x + 14, rowY);
    }

    // Scrollbar track + thumb
    const trackX = sp.x + sp.w - 14;
    const trackY = sp.y + 44;
    const trackH = sp.h - 50;
    ctx.fillStyle = '#1e293b';
    ctx.fillRect(trackX, trackY, 8, trackH);
    const maxOffset = LOG_LINE_COUNT - VISIBLE_LOG_LINES;
    const thumbH = Math.max(36, (VISIBLE_LOG_LINES / LOG_LINE_COUNT) * trackH);
    const thumbY = trackY + (state.scrollPaneOffset / maxOffset) * (trackH - thumbH);
    ctx.fillStyle = '#38bdf8';
    ctx.fillRect(trackX, thumbY, 8, thumbH);

    // Simulated Terminal window for phone keyboard testing
    ctx.fillStyle = '#020617';
    ctx.fillRect(260, 220, 920, 520);
    ctx.strokeStyle = '#475569';
    ctx.lineWidth = 2;
    ctx.strokeRect(260, 220, 920, 520);
    ctx.fillStyle = '#1e293b';
    ctx.fillRect(260, 220, 920, 42);
    ctx.fillStyle = '#94a3b8';
    ctx.font = 'bold 19px monospace';
    ctx.fillText('HID Keyboard & Mouse Live Monitor', 280, 248);

    ctx.fillStyle = '#38bdf8';
    ctx.font = '21px monospace';
    ctx.fillText(`Last Event: ${state.lastEventLabel}`, 284, 300);
    ctx.fillStyle = '#a7f3d0';
    ctx.fillText(
      `Cursor: (${state.cursorX}, ${state.cursorY})  Buttons: 0b${state.buttons.toString(2).padStart(3, '0')}`,
      284,
      336
    );
    ctx.fillStyle = '#cbd5e1';
    ctx.fillText(`Recent HID Keys: ${state.keyHistory.join('  ') || '(none yet)'}`, 284, 372);

    ctx.fillStyle = '#f8fafc';
    ctx.font = '24px monospace';
    const lines = state.typedText.split('\n');
    lines.forEach((line, i) => {
      ctx.fillText(line + (i === lines.length - 1 ? '█' : ''), 284, 430 + i * 36);
    });

    // Click ripples
    state.clicks.forEach((c) => {
      ctx.beginPath();
      ctx.arc(c.x, c.y, 16, 0, Math.PI * 2);
      ctx.strokeStyle = c.right ? '#f97316' : '#22c55e';
      ctx.lineWidth = 3;
      ctx.stroke();
    });

    // Host OS cursor
    ctx.save();
    ctx.translate(state.cursorX, state.cursorY);
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.lineTo(0, 28);
    ctx.lineTo(8, 21);
    ctx.lineTo(19, 25);
    ctx.closePath();
    ctx.fillStyle = (state.buttons & 2) !== 0 ? '#fb923c' : (state.buttons & 1) !== 0 ? '#4ade80' : '#ffffff';
    ctx.fill();
    ctx.strokeStyle = '#000000';
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.restore();
  }

  // Push rendered frames into the #screen <img> in MJPEG mode
  setInterval(() => {
    const img = document.querySelector<HTMLImageElement>('#screen img, img#screen');
    if (!img) return;
    if (!dirty && img.src.startsWith('data:image/jpeg')) return;
    dirty = false;
    renderMockDesktop();
    img.src = canvas.toDataURL('image/jpeg', 0.82);
  }, 50);
}

export async function startMocks() {
  // Auto-authenticate and select MJPEG so mock desktop renders immediately on mobile
  if (!existToken()) {
    setToken('mocked_token');
  }
  storage.setVideoMode('mjpeg');

  installMockApiAdapter();
  installMockHidAndScreen();

  // MSW requires a Secure Context (localhost or HTTPS); skip gracefully on LAN HTTP IPs
  if (typeof navigator !== 'undefined' && 'serviceWorker' in navigator) {
    try {
      await worker.start({ onUnhandledRequest: 'bypass' });
    } catch (err) {
      console.warn('[Mock] ServiceWorker unavailable on plain HTTP LAN; using in-memory adapter.', err);
    }
  }
}
