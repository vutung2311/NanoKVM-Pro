import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Button } from 'antd';
import clsx from 'clsx';
import { useAtom, useAtomValue } from 'jotai';
import {
  ArrowDownIcon,
  ArrowLeftIcon,
  ArrowRightIcon,
  ArrowUpIcon,
  ChevronDownIcon
} from 'lucide-react';
import { useTranslation } from 'react-i18next';

import { enqueueHidKeyTap, enqueueHidText, hidTapQueue, resolveHidChar } from '@/lib/char-hid.ts';
import { ModifierBits } from '@/lib/keymap.ts';
import { registerMobileKeyboardController } from '@/lib/mobile-keyboard-focus.ts';
import { isKeyboardEnableAtom, isMobileKeyboardOpenAtom } from '@/jotai/keyboard.ts';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';
import { useVisualViewport } from '@/hooks/useVisualViewport.ts';

const SENTINEL = '\u200B\u200B';

type ModifierKeyId = 'ctrl' | 'alt' | 'shift' | 'meta';
type StickyState = 'off' | 'oneshot' | 'locked';

const MODIFIER_BITS: Record<ModifierKeyId, number> = {
  ctrl: ModifierBits.LeftCtrl,
  alt: ModifierBits.LeftAlt,
  shift: ModifierBits.LeftShift,
  meta: ModifierBits.LeftMeta
};

const DIRECT_CONTROL_KEYS: Record<string, string> = {
  Escape: 'Escape',
  Tab: 'Tab',
  ArrowUp: 'ArrowUp',
  ArrowDown: 'ArrowDown',
  ArrowLeft: 'ArrowLeft',
  ArrowRight: 'ArrowRight',
  Home: 'Home',
  End: 'End',
  PageUp: 'PageUp',
  PageDown: 'PageDown',
  Delete: 'Delete',
  Insert: 'Insert',
  F1: 'F1',
  F2: 'F2',
  F3: 'F3',
  F4: 'F4',
  F5: 'F5',
  F6: 'F6',
  F7: 'F7',
  F8: 'F8',
  F9: 'F9',
  F10: 'F10',
  F11: 'F11',
  F12: 'F12'
};

const FN_KEYS = [
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
  'F9',
  'F10',
  'F11',
  'F12',
  'Home',
  'End',
  'PageUp',
  'PageDown',
  'Insert'
];

export const MobileKeyboard = () => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();
  const viewport = useVisualViewport();

  const [isOpen, setIsOpen] = useAtom(isMobileKeyboardOpenAtom);
  const isKeyboardEnable = useAtomValue(isKeyboardEnableAtom);
  const [showFnRow, setShowFnRow] = useState(false);
  const [modifiers, setModifiers] = useState<Record<ModifierKeyId, StickyState>>({
    ctrl: 'off',
    alt: 'off',
    shift: 'off',
    meta: 'off'
  });

  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const isComposingRef = useRef(false);
  const committedTextRef = useRef('');
  const accessoryInteractingRef = useRef(false);
  const accessoryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const blurTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastBlurAtRef = useRef(0);
  const modifiersRef = useRef(modifiers);
  modifiersRef.current = modifiers;

  const resetSentinel = useCallback(() => {
    const el = textareaRef.current;
    if (!el) return;
    committedTextRef.current = '';
    el.value = SENTINEL;
    try {
      el.setSelectionRange(SENTINEL.length, SENTINEL.length);
    } catch {
      // Ignore selection errors when blurred
    }
  }, []);

  const getActiveModifierMask = useCallback((state = modifiersRef.current): number => {
    let mask = 0;
    (Object.keys(MODIFIER_BITS) as ModifierKeyId[]).forEach((id) => {
      if (state[id] !== 'off') {
        mask |= MODIFIER_BITS[id];
      }
    });
    return mask;
  }, []);

  const clearOneShotModifiers = useCallback(() => {
    setModifiers((prev) => {
      let changed = false;
      const next = { ...prev };
      (Object.keys(next) as ModifierKeyId[]).forEach((id) => {
        if (next[id] === 'oneshot') {
          next[id] = 'off';
          changed = true;
        }
      });
      return changed ? next : prev;
    });
  }, []);

  const focusInput = useCallback(() => {
    if (blurTimerRef.current) {
      clearTimeout(blurTimerRef.current);
      blurTimerRef.current = null;
    }
    const el = textareaRef.current;
    if (!el) return;
    if (document.activeElement !== el) {
      resetSentinel();
      el.focus({ preventScroll: true });
    }
    setIsOpen(true);
  }, [resetSentinel, setIsOpen]);

  const blurInput = useCallback(() => {
    if (blurTimerRef.current) {
      clearTimeout(blurTimerRef.current);
      blurTimerRef.current = null;
    }
    accessoryInteractingRef.current = false;
    isComposingRef.current = false;
    committedTextRef.current = '';
    const el = textareaRef.current;
    el?.blur();
    setIsOpen(false);
    setShowFnRow(false);
    setModifiers({ ctrl: 'off', alt: 'off', shift: 'off', meta: 'off' });
    hidTapQueue.clear();
  }, [setIsOpen]);

  const toggleInput = useCallback(() => {
    const el = textareaRef.current;
    const recentlyBlurred = Date.now() - lastBlurAtRef.current < 250;
    if (isOpen || document.activeElement === el || recentlyBlurred) {
      blurInput();
    } else {
      focusInput();
    }
  }, [blurInput, focusInput, isOpen]);

  useEffect(() => {
    return () => {
      if (blurTimerRef.current) clearTimeout(blurTimerRef.current);
      if (accessoryTimerRef.current) clearTimeout(accessoryTimerRef.current);
    };
  }, []);

  useEffect(() => {
    if (!isKeyboardEnable && isOpen) {
      blurInput();
    }
  }, [blurInput, isKeyboardEnable, isOpen]);

  useEffect(() => {
    return registerMobileKeyboardController({
      focus: focusInput,
      blur: blurInput,
      toggle: toggleInput
    });
  }, [blurInput, focusInput, toggleInput]);

  function handleKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    // Prevent document-level desktop Keyboard listener from double-sending
    e.stopPropagation();

    if (isComposingRef.current || e.nativeEvent.isComposing) {
      return;
    }

    const mappedControl = DIRECT_CONTROL_KEYS[e.key];
    if (mappedControl) {
      e.preventDefault();
      let hwMod = getActiveModifierMask();
      if (e.ctrlKey) hwMod |= ModifierBits.LeftCtrl;
      if (e.altKey) hwMod |= ModifierBits.LeftAlt;
      if (e.shiftKey) hwMod |= ModifierBits.LeftShift;
      if (e.metaKey) hwMod |= ModifierBits.LeftMeta;

      enqueueHidKeyTap(mappedControl, hwMod);
      clearOneShotModifiers();
      resetSentinel();
      return;
    }

    // Hardware keyboard shortcuts (e.g. Ctrl+C on a paired Bluetooth keyboard)
    if ((e.ctrlKey || e.altKey || e.metaKey) && e.key.length === 1) {
      e.preventDefault();
      let hwMod = getActiveModifierMask();
      if (e.ctrlKey) hwMod |= ModifierBits.LeftCtrl;
      if (e.altKey) hwMod |= ModifierBits.LeftAlt;
      if (e.shiftKey) hwMod |= ModifierBits.LeftShift;
      if (e.metaKey) hwMod |= ModifierBits.LeftMeta;

      enqueueHidText(e.key.toLowerCase(), hwMod);
      clearOneShotModifiers();
      resetSentinel();
    }
  }

  function handleKeyUp(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    e.stopPropagation();
  }

  /**
   * Unified streaming buffer diff:
   * - Streams characters immediately even while Android/iOS IMEs are actively composing a word.
   * - Preserves the active IME composition buffer until composition ends or Enter is pressed,
   *   then restores SENTINEL so Backspace on an empty prompt always works without state flags.
   */
  function syncBufferDiff(rawValue: string, composing: boolean) {
    let sentinelCount = 0;
    while (sentinelCount < rawValue.length && rawValue[sentinelCount] === '\u200B') {
      sentinelCount++;
    }

    const currentText = rawValue.replace(/\u200B/g, '');
    const prevText = committedTextRef.current;
    const extraMod = getActiveModifierMask();

    // Case 1: Backspace pressed when no user text was in the buffer (sentinel shrunk)
    if (prevText.length === 0 && currentText.length === 0 && sentinelCount < SENTINEL.length) {
      const deletedCount = SENTINEL.length - sentinelCount;
      for (let i = 0; i < deletedCount; i++) {
        enqueueHidKeyTap('Backspace', i === 0 ? extraMod : 0);
      }
      clearOneShotModifiers();
      resetSentinel();
      return;
    }

    // Case 2: Compute common code-point prefix between already-sent text and current buffer text
    const prevChars = Array.from(prevText);
    const currChars = Array.from(currentText);
    let commonLen = 0;
    const minLen = Math.min(prevChars.length, currChars.length);
    while (commonLen < minLen && prevChars[commonLen] === currChars[commonLen]) {
      commonLen++;
    }

    // Only emit Backspace for removed characters that actually produced a HID keystroke on the host
    let backspacesNeeded = 0;
    for (let i = commonLen; i < prevChars.length; i++) {
      if (resolveHidChar(prevChars[i])) {
        backspacesNeeded++;
      }
    }
    const appendedText = currChars.slice(commonLen).join('');

    for (let i = 0; i < backspacesNeeded; i++) {
      enqueueHidKeyTap('Backspace', i === 0 && appendedText.length === 0 ? extraMod : 0);
    }

    if (appendedText.length > 0) {
      if (enqueueHidText(appendedText, extraMod)) {
        clearOneShotModifiers();
      }
    } else if (backspacesNeeded > 0) {
      clearOneShotModifiers();
    }

    const hasNewline = currentText.includes('\n') || currentText.includes('\r');
    if (!composing || hasNewline || currentText.length === 0) {
      isComposingRef.current = false;
      resetSentinel();
    } else {
      committedTextRef.current = currentText;
    }
  }

  function handleInput(e: React.FormEvent<HTMLTextAreaElement>) {
    syncBufferDiff(e.currentTarget.value, isComposingRef.current);
  }

  function handleCompositionStart() {
    isComposingRef.current = true;
  }

  function handleCompositionEnd(e: React.CompositionEvent<HTMLTextAreaElement>) {
    isComposingRef.current = false;
    syncBufferDiff(e.currentTarget.value, false);
  }

  function handleFocus() {
    const el = textareaRef.current;
    if (el && el.value.length === 0) {
      resetSentinel();
    }
    setIsOpen(true);
  }

  function handleBlur() {
    lastBlurAtRef.current = Date.now();

    if (accessoryInteractingRef.current) {
      keepKeyboardFocused();
      return;
    }

    if (blurTimerRef.current) {
      clearTimeout(blurTimerRef.current);
    }

    blurTimerRef.current = setTimeout(() => {
      blurTimerRef.current = null;
      if (accessoryInteractingRef.current || document.activeElement === textareaRef.current) {
        return;
      }
      isComposingRef.current = false;
      committedTextRef.current = '';
      setIsOpen(false);
      setShowFnRow(false);
    }, 100);
  }

  function markAccessoryInteraction() {
    accessoryInteractingRef.current = true;
    if (accessoryTimerRef.current) {
      clearTimeout(accessoryTimerRef.current);
    }
    accessoryTimerRef.current = setTimeout(() => {
      accessoryInteractingRef.current = false;
      accessoryTimerRef.current = null;
    }, 300);
  }

  function keepKeyboardFocused() {
    const el = textareaRef.current;
    if (el && document.activeElement !== el) {
      el.focus({ preventScroll: true });
    }
  }

  function cycleModifier(id: ModifierKeyId) {
    keepKeyboardFocused();
    setModifiers((prev) => {
      const current = prev[id];
      const nextState: StickyState =
        current === 'off' ? 'oneshot' : current === 'oneshot' ? 'locked' : 'off';
      return { ...prev, [id]: nextState };
    });
  }

  function tapSpecialKey(codeName: string, forcedMask = 0) {
    keepKeyboardFocused();
    const extraMod = getActiveModifierMask() | forcedMask;
    enqueueHidKeyTap(codeName, extraMod);
    clearOneShotModifiers();
  }

  function preventMouseBlur(e: React.MouseEvent) {
    e.preventDefault();
  }

  const keyBtnClass =
    'flex h-8 shrink-0 items-center justify-center px-2.5 text-xs font-medium';

  return (
    <>
      {/* Hidden sentinel textarea anchored at (0,0) with 16px font so iOS Safari never zooms or scrolls on focus */}
      <textarea
        ref={textareaRef}
        defaultValue={SENTINEL}
        lang="en"
        aria-label={t('keyboard.title')}
        autoComplete="off"
        autoCorrect="off"
        autoCapitalize="none"
        spellCheck={false}
        inputMode="text"
        enterKeyHint="enter"
        tabIndex={-1}
        onFocus={handleFocus}
        onBlur={handleBlur}
        onKeyDown={handleKeyDown}
        onKeyUp={handleKeyUp}
        onInput={handleInput}
        onCompositionStart={handleCompositionStart}
        onCompositionEnd={handleCompositionEnd}
        style={{
          position: 'fixed',
          top: 0,
          left: 0,
          width: '1px',
          height: '1px',
          opacity: 0,
          padding: 0,
          border: 0,
          fontSize: '16px',
          lineHeight: 1,
          caretColor: 'transparent',
          pointerEvents: 'none',
          zIndex: -1
        }}
      />

      {isTouchDevice && isOpen && (
        <div
          className="fixed left-0 right-0 z-[1001] select-none border-0 border-t border-solid border-neutral-800 bg-neutral-900/90 text-neutral-300 backdrop-blur-md"
          style={{
            bottom: `${viewport.bottomInset}px`,
            paddingLeft: 'max(6px, var(--safe-left))',
            paddingRight: 'max(6px, var(--safe-right))',
            paddingBottom: viewport.bottomInset > 0 ? '2px' : 'max(4px, var(--safe-bottom))'
          }}
          onTouchStartCapture={markAccessoryInteraction}
          onPointerDownCapture={markAccessoryInteraction}
          onMouseDown={preventMouseBlur}
        >
          {/* Optional expandable Fn & Navigation strip */}
          {showFnRow && (
            <div className="no-scrollbar flex items-center gap-1 overflow-x-auto border-0 border-b border-solid border-neutral-800 px-1 py-1">
              <Button
                size="small"
                color="danger"
                variant="filled"
                onMouseDown={preventMouseBlur}
                onClick={() =>
                  tapSpecialKey('Delete', ModifierBits.LeftCtrl | ModifierBits.LeftAlt)
                }
                className="flex h-7 shrink-0 items-center justify-center px-2.5 text-xs font-medium"
              >
                Ctrl+Alt+Del
              </Button>

              {FN_KEYS.map((fnKey) => (
                <Button
                  key={fnKey}
                  size="small"
                  color="default"
                  variant="filled"
                  onMouseDown={preventMouseBlur}
                  onClick={() => tapSpecialKey(fnKey)}
                  className="flex h-7 min-w-[36px] shrink-0 items-center justify-center px-2 text-xs font-medium"
                >
                  {fnKey === 'PageUp'
                    ? 'PgUp'
                    : fnKey === 'PageDown'
                      ? 'PgDn'
                      : fnKey === 'Insert'
                        ? 'Ins'
                        : fnKey}
                </Button>
              ))}
            </div>
          )}

          {/* Primary 1-row quick modifier & navigation accessory bar */}
          <div className="flex items-center gap-1 py-1">
            <div className="no-scrollbar flex min-w-0 flex-1 items-center gap-1 overflow-x-auto px-0.5">
              <Button
                size="small"
                color="default"
                variant="filled"
                onMouseDown={preventMouseBlur}
                onClick={() => tapSpecialKey('Escape')}
                className={clsx(keyBtnClass, 'min-w-[40px]')}
              >
                Esc
              </Button>

              <Button
                size="small"
                color="default"
                variant="filled"
                onMouseDown={preventMouseBlur}
                onClick={() => tapSpecialKey('Tab')}
                className={clsx(keyBtnClass, 'min-w-[40px]')}
              >
                Tab
              </Button>

              {(
                [
                  { id: 'ctrl', label: 'Ctrl' },
                  { id: 'alt', label: 'Alt' },
                  { id: 'shift', label: 'Shift' },
                  { id: 'meta', label: 'Win' }
                ] as { id: ModifierKeyId; label: string }[]
              ).map(({ id, label }) => {
                const state = modifiers[id];
                return (
                  <Button
                    key={id}
                    size="small"
                    color={state === 'off' ? 'default' : 'primary'}
                    variant={state === 'locked' ? 'solid' : 'filled'}
                    aria-pressed={state !== 'off'}
                    onMouseDown={preventMouseBlur}
                    onClick={() => cycleModifier(id)}
                    className="relative flex h-8 min-w-[42px] shrink-0 items-center justify-center px-2.5 text-xs font-medium"
                  >
                    {label}
                  </Button>
                );
              })}

              <Button
                size="small"
                color="default"
                variant="filled"
                aria-label="Arrow Left"
                icon={<ArrowLeftIcon size={15} aria-hidden="true" />}
                onMouseDown={preventMouseBlur}
                onClick={() => tapSpecialKey('ArrowLeft')}
                className={clsx(keyBtnClass, 'min-w-[36px]')}
              />
              <Button
                size="small"
                color="default"
                variant="filled"
                aria-label="Arrow Down"
                icon={<ArrowDownIcon size={15} aria-hidden="true" />}
                onMouseDown={preventMouseBlur}
                onClick={() => tapSpecialKey('ArrowDown')}
                className={clsx(keyBtnClass, 'min-w-[36px]')}
              />
              <Button
                size="small"
                color="default"
                variant="filled"
                aria-label="Arrow Up"
                icon={<ArrowUpIcon size={15} aria-hidden="true" />}
                onMouseDown={preventMouseBlur}
                onClick={() => tapSpecialKey('ArrowUp')}
                className={clsx(keyBtnClass, 'min-w-[36px]')}
              />
              <Button
                size="small"
                color="default"
                variant="filled"
                aria-label="Arrow Right"
                icon={<ArrowRightIcon size={15} aria-hidden="true" />}
                onMouseDown={preventMouseBlur}
                onClick={() => tapSpecialKey('ArrowRight')}
                className={clsx(keyBtnClass, 'min-w-[36px]')}
              />

              <Button
                size="small"
                color="default"
                variant="filled"
                onMouseDown={preventMouseBlur}
                onClick={() => tapSpecialKey('Delete')}
                className={clsx(keyBtnClass, 'min-w-[40px]')}
              >
                Del
              </Button>

              <Button
                size="small"
                color={showFnRow ? 'primary' : 'default'}
                variant="filled"
                aria-expanded={showFnRow}
                onMouseDown={preventMouseBlur}
                onClick={() => {
                  keepKeyboardFocused();
                  setShowFnRow((v) => !v);
                }}
                className={clsx(keyBtnClass, 'min-w-[36px]')}
              >
                Fn
              </Button>
            </div>

            {/* Dismiss OS keyboard */}
            <Button
              size="small"
              color="default"
              variant="filled"
              aria-label="Hide keyboard"
              icon={<ChevronDownIcon size={17} aria-hidden="true" />}
              onClick={blurInput}
              className="flex h-8 w-8 shrink-0 items-center justify-center p-0"
            />
          </div>
        </div>
      )}
    </>
  );
};
