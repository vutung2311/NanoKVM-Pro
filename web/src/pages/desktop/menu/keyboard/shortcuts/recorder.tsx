import { useEffect, useRef, useState } from 'react';
import { Button, Checkbox, Divider, Input, InputRef, Modal, Tag } from 'antd';
import { useSetAtom } from 'jotai';
import { ClipboardCheckIcon, KeyboardIcon, Trash2Icon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import {
  ClipboardPermissionState,
  getClipboardPermissionState,
  requestClipboardPermission
} from '@/lib/clipboard.ts';
import { isModifier } from '@/lib/keymap.ts';
import { isKeyboardEnableAtom } from '@/jotai/keyboard.ts';
import { Kbd, KbdGroup } from '@/components/ui/kbd.tsx';
import { ScrollArea } from '@/components/ui/scroll-area.tsx';

import { KeyInfo, Shortcut } from './types.ts';

const MAX_KEYS = 6;

const SpecialKeyMap: Record<string, string> = {
  Space: 'Space',
  Backspace: '⌫',
  Enter: '↵',
  Tab: 'Tab',
  CapsLock: 'Caps',
  Escape: 'Esc',
  ArrowUp: '↑',
  ArrowDown: '↓',
  ArrowLeft: '←',
  ArrowRight: '→',
  Delete: 'Del',
  Insert: 'Ins',
  Home: 'Home',
  End: 'End',
  PageUp: 'PgUp',
  PageDown: 'PgDn'
};

const PunctuationMap: Record<string, string> = {
  Minus: '-',
  Equal: '=',
  BracketLeft: '[',
  BracketRight: ']',
  Backslash: '\\',
  Semicolon: ';',
  Quote: "'",
  Backquote: '`',
  Comma: ',',
  Period: '.',
  Slash: '/'
};

interface RecorderProps {
  shortcuts: Shortcut[];
  addShortcut: (shortcut: Shortcut) => void;
  delShortcut: (shortcut: Shortcut) => void;
  setIsRecording: (isRecording: boolean) => void;
}

export const Recorder = ({
  shortcuts,
  addShortcut,
  delShortcut,
  setIsRecording
}: RecorderProps) => {
  const { t } = useTranslation();
  const setIsKeyboardEnable = useSetAtom(isKeyboardEnableAtom);

  const [isModalOpen, setIsModalOpen] = useState(false);
  const [isFocused, setIsFocused] = useState(false);
  const [shortcutLabel, setShortcutLabel] = useState('');
  const [isPasteTag, setIsPasteTag] = useState(false);
  const [clipboardPermission, setClipboardPermission] =
    useState<ClipboardPermissionState>('prompt');

  const inputRef = useRef<InputRef | null>(null);
  const recordedKeysRef = useRef<KeyInfo[]>([]);

  useEffect(() => {
    setIsKeyboardEnable(!isModalOpen);
    setIsRecording(isModalOpen);

    if (!isModalOpen) return;

    void getClipboardPermissionState().then(setClipboardPermission);

    const timer = setTimeout(() => {
      inputRef.current?.focus();
    }, 100);

    return () => {
      clearTimeout(timer);
    };
  }, [isModalOpen]);

  useEffect(() => {
    if (!isFocused) return;

    const handleKeyDown = (event: KeyboardEvent) => {
      event.preventDefault();
      event.stopPropagation();

      const { key, code } = event;

      const isRecorded = recordedKeysRef.current.some((k) => k.code === code);
      if (isRecorded) return;

      if (recordedKeysRef.current.length >= MAX_KEYS) return;

      const keyInfo: KeyInfo = {
        code: code,
        label: formatKeyDisplay(key, code)
      };

      setShortcutLabel((prev) => (prev ? `${prev} + ${keyInfo.label}` : keyInfo.label));
      recordedKeysRef.current.push(keyInfo);
    };

    window.addEventListener('keydown', handleKeyDown);

    return () => {
      window.removeEventListener('keydown', handleKeyDown);
    };
  }, [isFocused]);

  const formatKeyDisplay = (key: string, code: string): string => {
    if (isModifier(code)) {
      if (code.startsWith('Control')) {
        return 'Ctrl';
      }
      if (code.startsWith('Shift')) {
        return 'Shift';
      }
      if (code.startsWith('Alt')) {
        return 'Alt';
      }
      if (code.startsWith('Meta')) {
        return 'Win';
      }
    }

    if (code.startsWith('Digit')) {
      return code.replace('Digit', '');
    }
    if (code.startsWith('Key')) {
      return code.replace('Key', '');
    }
    if (code.startsWith('Numpad')) {
      const numpadKey = code.replace('Numpad', '');
      return `Num${numpadKey}`;
    }
    if (code.startsWith('F') && /^F\d+$/.test(code)) {
      return code; // F1, F2, etc.
    }

    if (SpecialKeyMap[code]) {
      return SpecialKeyMap[code];
    }
    if (PunctuationMap[code]) {
      return PunctuationMap[code];
    }

    return key.toUpperCase();
  };

  function saveShortcut() {
    if (recordedKeysRef.current.length > 0) {
      addShortcut({
        keys: recordedKeysRef.current,
        tag: isPasteTag ? 'paste' : undefined
      });
    }

    clearShortcut();
    setIsPasteTag(false);
  }

  function clearShortcut() {
    setShortcutLabel('');
    recordedKeysRef.current = [];
  }

  async function handleRequestClipboardPermission() {
    const state = await requestClipboardPermission(t);
    setClipboardPermission(state);
  }

  function closeModal() {
    clearShortcut();
    setIsPasteTag(false);
    setIsModalOpen(false);
  }

  function toggleFullscreen() {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen();
      // @ts-expect-error - https://developer.mozilla.org/en-US/docs/Web/API/Keyboard/lock
      navigator.keyboard?.lock();
    } else {
      document.exitFullscreen();
      // @ts-expect-error - https://developer.mozilla.org/en-US/docs/Web/API/Keyboard/unlock
      navigator.keyboard?.unlock();
    }
  }

  return (
    <>
      <div
        className="flex h-[30px] cursor-pointer items-center space-x-1 rounded px-3 text-neutral-300 hover:bg-neutral-700/60"
        onClick={() => setIsModalOpen(true)}
      >
        <span>{t('keyboard.shortcut.custom')}</span>
      </div>

      <Modal
        width={500}
        title={t('keyboard.shortcut.title')}
        keyboard={false}
        footer={null}
        open={isModalOpen}
        onCancel={closeModal}
      >
        <div>
          <span className="text-neutral-500">{t('keyboard.shortcut.captureTips')}</span>
          <a className="px-1 text-blue-500/80" onClick={toggleFullscreen}>
            {t('keyboard.shortcut.enterFullScreen')}
          </a>
        </div>

        <div className="flex items-center space-x-0.5 pt-6 pb-3">
          <Input
            ref={inputRef}
            placeholder={t('keyboard.shortcut.capture')}
            prefix={<KeyboardIcon size={16} className="text-neutral-500" />}
            value={shortcutLabel}
            onFocus={() => setIsFocused(true)}
            onBlur={() => setIsFocused(false)}
          />

          <Button onClick={clearShortcut}>{t('keyboard.shortcut.clear')}</Button>
        </div>

        <div className="flex flex-col space-y-2 pb-5">
          <div className="flex items-center justify-between">
            <Checkbox checked={isPasteTag} onChange={(e) => setIsPasteTag(e.target.checked)}>
              {t('keyboard.shortcut.pasteTagOption')}
            </Checkbox>

            {isPasteTag && (
              <Tag
                color={
                  clipboardPermission === 'granted'
                    ? 'green'
                    : clipboardPermission === 'denied' || clipboardPermission === 'unsupported'
                      ? 'red'
                      : 'gold'
                }
                style={{ marginInlineEnd: 0 }}
              >
                {t(`keyboard.shortcut.permission.${clipboardPermission}`)}
              </Tag>
            )}
          </div>

          {isPasteTag && (
            <div className="box-border flex items-center justify-between gap-3 rounded bg-neutral-800/60 px-3 py-2 text-xs text-neutral-400">
              <span>{t('keyboard.shortcut.pasteTagDesc')}</span>
              <Button
                size="small"
                className="shrink-0"
                icon={<ClipboardCheckIcon size={14} />}
                disabled={clipboardPermission === 'unsupported'}
                onClick={handleRequestClipboardPermission}
              >
                {t('keyboard.shortcut.requestClipboard')}
              </Button>
            </div>
          )}
        </div>

        <div className="flex w-full justify-center pb-3">
          <Button type="primary" className="min-w-24" onClick={saveShortcut}>
            {t('keyboard.shortcut.save')}
          </Button>
        </div>

        {shortcuts.length > 0 && (
          <>
            <Divider />

            <ScrollArea className="[&>[data-radix-scroll-area-viewport]]:max-h-[300px]">
              {shortcuts.map((shortcut) => (
                <div
                  key={shortcut.id}
                  className="box-border flex items-center justify-between gap-2 rounded p-2 hover:bg-neutral-700/50"
                >
                  <div className="flex items-center space-x-1">
                    {shortcut.keys.map((key, index) => (
                      <KbdGroup key={index}>
                        <Kbd>{key.label}</Kbd>
                      </KbdGroup>
                    ))}
                    {shortcut.tag === 'paste' && (
                      <Tag color="blue" style={{ marginInlineEnd: 0 }} className="ml-2 shrink-0 text-xs">
                        {t('keyboard.shortcut.pasteTag')}
                      </Tag>
                    )}
                  </div>

                  <div
                    className="flex size-[20px] cursor-pointer items-center justify-center rounded-sm text-neutral-500 hover:text-red-500"
                    onClick={() => delShortcut(shortcut)}
                  >
                    <Trash2Icon size={16} />
                  </div>
                </div>
              ))}
            </ScrollArea>
          </>
        )}
      </Modal>
    </>
  );
};
