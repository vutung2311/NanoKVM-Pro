import { useEffect, useState } from 'react';
import { Badge, Button, Modal, Tooltip } from 'antd';
import clsx from 'clsx';
import { useAtom, useSetAtom } from 'jotai';
import {
  BadgeInfoIcon,
  CircleArrowUpIcon,
  MonitorIcon,
  PaletteIcon,
  SettingsIcon,
  SmartphoneIcon,
  UserRoundIcon
} from 'lucide-react';
import { useTranslation } from 'react-i18next';
import semver from 'semver';

import * as api from '@/api/application.ts';
import * as ls from '@/lib/localstorage.ts';
import { isKeyboardEnableAtom } from '@/jotai/keyboard.ts';
import { isSettingsOpenAtom, settingTabAtom, submenuOpenCountAtom } from '@/jotai/settings.ts';
import { Tailscale as TailscaleIcon } from '@/components/icons/tailscale';
import { ScrollArea } from '@/components/ui/scroll-area.tsx';
import { useTouchDevice } from '@/hooks/useTouchDevice.ts';

import { About } from './about';
import { Account } from './account';
import { Appearance } from './appearance';
import { Device } from './device';
import { Screen } from './screen';
import { Tailscale } from './tailscale';
import { Update } from './update';

export const Settings = () => {
  const { t } = useTranslation();
  const isTouchDevice = useTouchDevice();

  const [isSettingsOpen, setIsSettingsOpen] = useAtom(isSettingsOpenAtom);
  const [settingTab, setSettingTab] = useAtom(settingTabAtom);
  const setIsKeyboardEnable = useSetAtom(isKeyboardEnableAtom);
  const setSubmenuOpenCount = useSetAtom(submenuOpenCountAtom);

  const [isLocked, setIsLocked] = useState(false);

  const [isUpdateAvailable, setIsUpdateAvailable] = useState(false);

  const tabs = [
    { id: 'about', icon: <BadgeInfoIcon size={16} />, component: <About /> },
    { id: 'appearance', icon: <PaletteIcon size={16} />, component: <Appearance /> },
    { id: 'screen', icon: <MonitorIcon size={16} />, component: <Screen /> },
    { id: 'device', icon: <SmartphoneIcon size={16} />, component: <Device /> },
    {
      id: 'tailscale',
      icon: <TailscaleIcon />,
      component: <Tailscale setIsLocked={setIsLocked} />
    },
    {
      id: 'update',
      icon: <CircleArrowUpIcon size={16} />,
      component: <Update setIsLocked={setIsLocked} />
    },
    { id: 'account', icon: <UserRoundIcon size={16} />, component: <Account /> }
  ];

  useEffect(() => {
    const skip = ls.getSkipUpdate();
    if (!skip) {
      checkForUpdates();
    }
    return () => {};
  }, []);

  function checkForUpdates() {
    api.getVersion().then((rsp: any) => {
      if (rsp.code !== 0) {
        return;
      }

      if (semver.gt(rsp.data.latest, rsp.data.current)) {
        setIsUpdateAvailable(true);
      }
    });
  }

  function changeTab(tab: string) {
    if (isLocked) {
      return;
    }

    setSettingTab(tab);

    if (isUpdateAvailable && tab === 'update') {
      setIsUpdateAvailable(false);
      ls.setSkipUpdate(true);
    }
  }

  function openModal() {
    setIsSettingsOpen(true);
    setIsKeyboardEnable(false);
    setSubmenuOpenCount((count) => count + 1);
  }

  function closeModal() {
    if (isLocked) {
      return;
    }

    setIsKeyboardEnable(true);
    setIsSettingsOpen(false);
    setSettingTab('about');
    setSubmenuOpenCount((count) => Math.max(0, count - 1));
  }

  const triggerButton = (
    <Button
      type="text"
      size="small"
      aria-label={t('settings.title')}
      className="kvm-touch-target flex h-[30px] w-[30px] shrink-0 items-center justify-center p-0"
      onClick={openModal}
    >
      <Badge dot={isUpdateAvailable} color="blue" offset={[0, 2]}>
        <div className="pt-[3px] text-neutral-300 hover:text-white">
          <SettingsIcon size={18} aria-hidden="true" />
        </div>
      </Badge>
    </Button>
  );

  return (
    <>
      {isTouchDevice ? (
        triggerButton
      ) : (
        <Tooltip title={t('settings.title')} placement="bottom" mouseEnterDelay={0.6}>
          {triggerButton}
        </Tooltip>
      )}

      <Modal
        open={isSettingsOpen}
        width={'94%'}
        centered={true}
        footer={null}
        destroyOnHidden={true}
        onCancel={closeModal}
        style={{ maxWidth: '1080px' }}
        styles={{ content: { padding: 0 } }}
      >
        <div className="flex h-[85dvh] max-h-[700px] flex-col rounded-lg outline outline-1 outline-neutral-700 sm:h-[80dvh] sm:flex-row">
          <div className="no-scrollbar flex shrink-0 flex-row items-center gap-1 overflow-x-auto rounded-t-lg border-b border-neutral-700/70 bg-neutral-800 px-2 py-2 pr-10 sm:h-full sm:w-1/5 sm:max-w-[260px] sm:flex-col sm:items-stretch sm:space-y-0.5 sm:overflow-visible sm:rounded-l-lg sm:rounded-tr-none sm:border-b-0 sm:px-1 sm:py-0 md:w-1/4 md:px-2">
            <div className="hidden px-3 pt-10 text-xl sm:block">{t('settings.title')}</div>
            <div className="hidden sm:block sm:h-5" />
            {tabs.map((tab) => (
              <div
                key={tab.id}
                className={clsx(
                  'flex shrink-0 cursor-pointer select-none items-center space-x-2 rounded-lg px-2.5 py-2 sm:px-3',
                  tab.id === settingTab ? 'bg-neutral-700/80 text-white' : 'hover:bg-neutral-700'
                )}
                onClick={() => changeTab(tab.id)}
              >
                <div className="h-[16px] w-[16px] shrink-0">{tab.icon}</div>

                {isUpdateAvailable && tab.id === 'update' ? (
                  <Badge dot color="blue" offset={[6, 3]}>
                    <span className="truncate text-xs sm:text-sm">
                      {t(`settings.${tab.id}.title`)}
                    </span>
                  </Badge>
                ) : (
                  <span className="truncate text-xs sm:text-sm">
                    {t(`settings.${tab.id}.title`)}
                  </span>
                )}
              </div>
            ))}
          </div>

          <ScrollArea className="min-h-0 flex-1 rounded-b-lg bg-neutral-900/50 px-3 sm:h-full sm:w-full sm:rounded-bl-none sm:rounded-r-lg md:px-5">
            <div className="flex h-full w-full justify-center">
              <div className="w-full max-w-[600px] pb-10 pt-6 sm:pt-14">
                <>{tabs.find((tab) => tab.id === settingTab)?.component}</>
              </div>
            </div>
          </ScrollArea>
        </div>
      </Modal>
    </>
  );
};
