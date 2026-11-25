import { atom } from 'jotai';

import type { Shortcut } from '@/pages/desktop/menu/keyboard/shortcuts/types.ts';

// is the keyboard enabled (Disable keyboard events when input is required)
export const isKeyboardEnableAtom = atom(true);

// is the virtual keyboard opened
export const isKeyboardOpenAtom = atom(false);

// leader key code for bypassing browser shortcuts (empty string means disabled)
export const leaderKeyAtom = atom('');

// custom shortcuts (including paste-tagged shortcuts)
export const shortcutsAtom = atom<Shortcut[]>([]);

// is caps lock active
export const isCapsLockActiveAtom = atom(false);

// is the mobile native OS keyboard active
export const isMobileKeyboardOpenAtom = atom(false);
