import { message } from 'antd';
import type { TFunction } from 'i18next';

import { paste } from '@/api/hid';

export type ClipboardPermissionState = 'granted' | 'prompt' | 'denied' | 'unsupported';

const MAX_PASTE_LENGTH = 1024;

export function isClipboardSupported(): boolean {
  return typeof navigator !== 'undefined' && Boolean(navigator.clipboard?.readText);
}

export function isASCII(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    if (value.charCodeAt(i) > 127) {
      return false;
    }
  }
  return true;
}

export async function getClipboardPermissionState(): Promise<ClipboardPermissionState> {
  if (!isClipboardSupported()) {
    return 'unsupported';
  }

  if (!navigator.permissions?.query) {
    return 'prompt';
  }

  try {
    const status = await navigator.permissions.query({
      name: 'clipboard-read' as Parameters<Permissions['query']>[0]['name']
    });
    return status.state;
  } catch {
    return 'prompt';
  }
}

export async function requestClipboardPermission(
  t: TFunction
): Promise<ClipboardPermissionState> {
  if (!isClipboardSupported()) {
    message.error(t('keyboard.shortcut.clipboardUnsupported'));
    return 'unsupported';
  }

  try {
    await navigator.clipboard.readText();
    message.success(t('keyboard.shortcut.clipboardGranted'));
    return 'granted';
  } catch (err) {
    if (err instanceof DOMException && err.name === 'NotAllowedError') {
      message.error(t('keyboard.shortcut.clipboardDenied'));
      return 'denied';
    }
    const state = await getClipboardPermissionState();
    if (state === 'denied') {
      message.error(t('keyboard.shortcut.clipboardDenied'));
    }
    return state;
  }
}

export async function pasteFromClipboard(t: TFunction): Promise<boolean> {
  if (!isClipboardSupported()) {
    message.error(t('keyboard.shortcut.clipboardUnsupported'));
    return false;
  }

  let text = '';
  try {
    text = await navigator.clipboard.readText();
  } catch (err) {
    if (err instanceof DOMException && err.name === 'NotAllowedError') {
      message.error(t('keyboard.shortcut.clipboardDenied'));
    } else {
      message.error(t('keyboard.shortcut.clipboardReadFailed'));
    }
    return false;
  }

  if (!text) {
    message.warning(t('keyboard.shortcut.clipboardEmpty'));
    return false;
  }

  if (!isASCII(text)) {
    message.error(t('keyboard.tips'));
    return false;
  }

  if (text.length > MAX_PASTE_LENGTH) {
    message.error(t('keyboard.shortcut.clipboardTooLong', { max: MAX_PASTE_LENGTH }));
    return false;
  }

  try {
    const rsp = await paste(text);
    if (rsp.code !== 0) {
      message.error(rsp.msg || t('keyboard.shortcut.pasteFailed'));
      return false;
    }
    message.success(t('keyboard.shortcut.pasteSuccess'));
    return true;
  } catch {
    message.error(t('keyboard.shortcut.pasteFailed'));
    return false;
  }
}
