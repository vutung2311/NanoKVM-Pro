import { useState } from 'react';
import { Tag } from 'antd';
import { useTranslation } from 'react-i18next';

import { pasteFromClipboard } from '@/lib/clipboard.ts';
import { KeyboardReport } from '@/lib/keyboard.ts';
import { client, MessageEvent } from '@/lib/websocket.ts';
import { Kbd, KbdGroup } from '@/components/ui/kbd.tsx';

import type { Shortcut as ShortcutInterface } from './types.ts';

type ShortcutProps = {
  shortcut: ShortcutInterface;
};

export const Shortcut = ({ shortcut }: ShortcutProps) => {
  const { t } = useTranslation();
  const [isLoading, setIsLoading] = useState(false);

  async function sendShortcut() {
    if (shortcut.tag === 'paste') {
      await pasteFromClipboard(t);
      return;
    }

    const keyboard = new KeyboardReport();

    shortcut.keys.forEach((key) => {
      const report = keyboard.keyDown(key.code);
      send(report);
    });

    const report = keyboard.reset();
    send(report);
  }

  function send(report: Uint8Array) {
    const data = new Uint8Array([MessageEvent.Keyboard, ...report]);
    client.send(data);
  }

  async function handleClick(): Promise<void> {
    if (isLoading) return;
    setIsLoading(true);

    try {
      await sendShortcut();
    } catch (err) {
      console.log(err);
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <div
      className="box-border flex h-[32px] w-full cursor-pointer items-center justify-between gap-3 rounded px-3 hover:bg-neutral-700/30"
      onClick={handleClick}
    >
      <div className="flex shrink-0 items-center space-x-1">
        {shortcut.keys.map((key, index) => (
          <KbdGroup key={index}>
            <Kbd>{key.label}</Kbd>
          </KbdGroup>
        ))}
      </div>

      {shortcut.tag === 'paste' && (
        <Tag color="blue" style={{ marginInlineEnd: 0 }} className="shrink-0 text-xs">
          {t('keyboard.shortcut.pasteTag')}
        </Tag>
      )}
    </div>
  );
};
