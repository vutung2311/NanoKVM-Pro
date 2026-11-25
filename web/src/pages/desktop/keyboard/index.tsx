import { useEffect, useRef } from 'react';
import { useAtom, useAtomValue, useSetAtom } from 'jotai';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/hid.ts';
import { getOperatingSystem } from '@/lib/browser.ts';
import { pasteFromClipboard } from '@/lib/clipboard.ts';
import { KeyboardReport } from '@/lib/keyboard.ts';
import { isModifier } from '@/lib/keymap';
import { client, MessageEvent } from '@/lib/websocket.ts';
import { isCapsLockActiveAtom, isKeyboardEnableAtom, shortcutsAtom } from '@/jotai/keyboard.ts';
import { DEFAULT_PASTE_SHORTCUT } from '@/pages/desktop/menu/keyboard/shortcuts/types.ts';

import { Recorder } from './recorder.tsx';
import { useAltGr } from './useAltGr.ts';
import { useLeaderKey } from './useLeaderKey.ts';
import { normalizeKeyCode } from './utils.ts';

function normalizeShortcutCode(code: string): string {
  if (code === 'ControlLeft' || code === 'ControlRight') return 'Control';
  if (code === 'ShiftLeft' || code === 'ShiftRight') return 'Shift';
  if (code === 'AltLeft' || code === 'AltRight') return 'Alt';
  if (code === 'MetaLeft' || code === 'MetaRight') return 'Meta';
  return code;
}

export const Keyboard = () => {
  const { t } = useTranslation();
  const os = getOperatingSystem();

  const isKeyboardEnabled = useAtomValue(isKeyboardEnableAtom);
  const setIsCapsLockActive = useSetAtom(isCapsLockActiveAtom);
  const [shortcuts, setShortcuts] = useAtom(shortcutsAtom);

  const keyboardRef = useRef(new KeyboardReport());
  const pressedKeys = useRef(new Set<string>());
  const suppressedKeysRef = useRef(new Set<string>());
  const shortcutsRef = useRef(shortcuts);
  shortcutsRef.current = shortcuts;
  const isComposing = useRef(false);

  useEffect(() => {
    api
      .getShortcuts()
      .then((rsp: any) => {
        if (rsp.code === 0 && Array.isArray(rsp.data?.shortcuts)) {
          setShortcuts(rsp.data.shortcuts);
        }
      })
      .catch((err) => {
        console.log(err);
      });
  }, [setShortcuts]);

  // Send key event helper
  const sendKeyEvent = (type: 'keydown' | 'keyup', code: string) => {
    const kb = keyboardRef.current;
    const report = type === 'keydown' ? kb.keyDown(code) : kb.keyUp(code);
    sendReport(report);
  };

  // Init leader key handler
  const leaderKey = useLeaderKey(pressedKeys, sendKeyEvent);
  const leaderKeyRef = useRef(leaderKey);
  leaderKeyRef.current = leaderKey;

  // Init AltGr key handler
  const altGr = useAltGr(os, pressedKeys, sendKeyEvent);
  const altGrRef = useRef(altGr);
  altGrRef.current = altGr;

  useEffect(() => {
    const suppressedKeys = suppressedKeysRef.current;

    document.addEventListener('keydown', handleKeyDown);
    document.addEventListener('keyup', handleKeyUp);
    document.addEventListener('compositionstart', handleCompositionStart);
    document.addEventListener('compositionend', handleCompositionEnd);
    window.addEventListener('blur', handleBlur);
    document.addEventListener('visibilitychange', handleVisibilityChange);

    function handleKeyDown(event: KeyboardEvent) {
      if (typeof event.getModifierState === 'function') {
        setIsCapsLockActive(event.getModifierState('CapsLock'));
      }

      if (!isKeyboardEnabled) return;
      if (isComposing.current || event.isComposing) return;

      event.preventDefault();
      event.stopPropagation();

      const code = normalizeKeyCode(os, event);
      if (!code || pressedKeys.current.has(code)) return;
      if (event.repeat && suppressedKeysRef.current.has(code)) return;
      suppressedKeysRef.current.delete(code);

      // Handle leader key
      const leaderHandled = leaderKeyRef.current.handleKeyDown(code);
      if (leaderHandled) {
        return;
      }

      // Intercept client-side paste shortcut
      const customPasteShortcuts = shortcutsRef.current.filter(
        (shortcut) => shortcut.tag === 'paste' && shortcut.keys.length > 0
      );
      const activePasteShortcuts =
        customPasteShortcuts.length > 0 ? customPasteShortcuts : [DEFAULT_PASTE_SHORTCUT];

      const candidateCodes = new Set(pressedKeys.current);
      candidateCodes.add(code);
      const candidateNormalized = new Set(Array.from(candidateCodes, normalizeShortcutCode));

      const matchedPasteShortcut = activePasteShortcuts.find((shortcut) => {
        const shortcutNormalized = new Set(
          shortcut.keys.map((k) => normalizeShortcutCode(k.code))
        );
        if (shortcutNormalized.size !== candidateNormalized.size) return false;
        return Array.from(shortcutNormalized).every((k) => candidateNormalized.has(k));
      });
      if (matchedPasteShortcut) {
        pressedKeys.current.forEach((pressedCode) => {
          suppressedKeysRef.current.add(pressedCode);
        });
        suppressedKeysRef.current.add(code);
        releaseKeys();
        void pasteFromClipboard(t);
        return;
      }

      // Handle AltGr key
      altGrRef.current.handleKeyDown(code, event.timeStamp);

      pressedKeys.current.add(code);
      sendKeyEvent('keydown', code);
    }

    function handleKeyUp(event: KeyboardEvent) {
      if (typeof event.getModifierState === 'function') {
        setIsCapsLockActive(event.getModifierState('CapsLock'));
      }

      if (!isKeyboardEnabled) return;
      if (isComposing.current || event.isComposing) return;

      event.preventDefault();
      event.stopPropagation();

      const code = normalizeKeyCode(os, event);
      if (!code) return;

      if (suppressedKeysRef.current.has(code)) {
        suppressedKeysRef.current.delete(code);
        if (code === 'MetaLeft' || code === 'MetaRight') {
          for (const key of Array.from(suppressedKeysRef.current)) {
            if (!isModifier(key)) {
              suppressedKeysRef.current.delete(key);
            }
          }
        }
        return;
      }

      // Handle leader key release
      const leaderHandled = leaderKeyRef.current.handleKeyUp(code);
      if (leaderHandled) {
        return;
      }

      // Handle AltGr key release
      const altGrHandled = altGrRef.current.handleKeyUp(code);
      if (altGrHandled) {
        return;
      }

      // Release Meta combinations (macOS compatibility)
      if (code === 'MetaLeft' || code === 'MetaRight') {
        releaseMetaCombinations();
      }

      pressedKeys.current.delete(code);
      sendKeyEvent('keyup', code);
    }

    function handleCompositionStart() {
      isComposing.current = true;
    }

    function handleCompositionEnd() {
      isComposing.current = false;
    }

    function handleBlur() {
      suppressedKeys.clear();
      releaseKeys();
    }

    function handleVisibilityChange() {
      if (document.hidden) {
        suppressedKeys.clear();
        releaseKeys();
      }
    }

    function releaseMetaCombinations() {
      const keysToRelease = Array.from(pressedKeys.current).filter((code) => !isModifier(code));
      for (const key of keysToRelease) {
        sendKeyEvent('keyup', key);
        pressedKeys.current.delete(key);
      }
    }

    function releaseKeys() {
      pressedKeys.current.forEach((code) => {
        sendKeyEvent('keyup', code);
      });
      pressedKeys.current.clear();

      leaderKeyRef.current.reset();
      altGrRef.current.reset();

      const report = keyboardRef.current.reset();
      sendReport(report);
    }

    return () => {
      document.removeEventListener('keydown', handleKeyDown);
      document.removeEventListener('keyup', handleKeyUp);
      document.removeEventListener('compositionstart', handleCompositionStart);
      document.removeEventListener('compositionend', handleCompositionEnd);
      window.removeEventListener('blur', handleBlur);
      document.removeEventListener('visibilitychange', handleVisibilityChange);

      suppressedKeys.clear();
      releaseKeys();
    };
  }, [isKeyboardEnabled]);

  function sendReport(report: Uint8Array) {
    const data = new Uint8Array([MessageEvent.Keyboard, ...report]);
    client.send(data);
  }

  return (
    <>
      <Recorder recordMode={leaderKey.recordMode} recordedKeys={leaderKey.recordedKeys} />
    </>
  );
};
