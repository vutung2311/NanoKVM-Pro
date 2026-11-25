export interface KeyInfo {
  code: string;
  label: string;
}

export interface Shortcut {
  id?: string;
  keys: KeyInfo[];
  tag?: string;
}

export const DEFAULT_PASTE_SHORTCUT: Shortcut = {
  keys: [
    { code: 'ControlLeft', label: 'Ctrl' },
    { code: 'AltLeft', label: 'Alt' },
    { code: 'ShiftLeft', label: 'Shift' },
    { code: 'KeyV', label: 'V' }
  ],
  tag: 'paste'
};
