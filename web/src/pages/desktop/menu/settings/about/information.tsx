import { useEffect, useState } from 'react';
import { Tooltip } from 'antd';
import clsx from 'clsx';
import { CircleHelpIcon, EthernetPortIcon, WifiIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/vm.ts';

type IP = {
  name: string;
  addr: string;
  version: string;
  type: string;
};

type Info = {
  image: string;
  ips: IP[];
  mdns: string;
  application: string;
  deviceKey: string;
  pn: string;
  arch: string;
};

// How often the SoC temperature is re-read while this panel is open.
const TEMPERATURE_INTERVAL_MS = 3000;

// The SoC starts throttling at its first thermal trip point (80 °C).
const TEMPERATURE_WARM = 65;
const TEMPERATURE_HOT = 80;

export const Information = () => {
  const { t } = useTranslation();

  const [information, setInformation] = useState<Info>();
  const [temperature, setTemperature] = useState<number>();

  useEffect(() => {
    api.getInfo().then((rsp: any) => {
      if (rsp.code !== 0) {
        console.log(rsp.msg);
        return;
      }

      setInformation(rsp.data);
    });
  }, []);

  useEffect(() => {
    let active = true;

    const update = () => {
      api
        .getTemperature()
        .then((rsp: any) => {
          if (!active) return;
          setTemperature(rsp.code === 0 ? rsp.data?.temperature : undefined);
        })
        .catch(() => {
          if (active) setTemperature(undefined);
        });
    };

    update();
    const timer = setInterval(update, TEMPERATURE_INTERVAL_MS);

    return () => {
      active = false;
      clearInterval(timer);
    };
  }, []);

  return (
    <>
      <div className="text-neutral-400">{t('settings.about.information')}</div>

      <div className="mt-5 flex w-full flex-col space-y-5">
        {/* IP list */}
        <div className="flex w-full items-start justify-between">
          <span>{t('settings.about.ip')}</span>
          {information?.ips && information.ips.length > 0 ? (
            <div className="flex flex-col justify-end space-y-1">
              {information.ips.map((ip) => (
                <div key={ip.addr} className="flex items-center justify-end space-x-2">
                  <span>{ip.addr}</span>
                  <div className="size-[16px] text-neutral-500">
                    {ip.type === 'Wireless' ? (
                      <WifiIcon size={16} />
                    ) : (
                      <EthernetPortIcon size={16} />
                    )}
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <span>-</span>
          )}
        </div>

        {/* mDNS */}
        {!!information?.mdns && (
          <div className="flex w-full items-center justify-between">
            <span>{t('settings.about.mdns')}</span>
            <span>{information.mdns}</span>
          </div>
        )}

        {/* image version */}
        <div className="flex w-full items-center justify-between">
          <div className="flex items-center space-x-2">
            <span>{t('settings.about.image')}</span>
            <Tooltip
              title={t('settings.about.imageTip')}
              className="cursor-pointer text-neutral-500"
              placement="right"
            >
              <CircleHelpIcon size={15} />
            </Tooltip>
          </div>

          <span>{information ? information.image : '-'}</span>
        </div>

        {/* application version */}
        <div className="flex w-full items-center justify-between">
          <div className="flex items-center space-x-2">
            <span>{t('settings.about.application')}</span>
            <Tooltip
              title={t('settings.about.applicationTip')}
              className="cursor-pointer text-neutral-500"
              placement="right"
            >
              <CircleHelpIcon size={15} />
            </Tooltip>
          </div>

          <span>{information ? information.application : '-'}</span>
        </div>

        {/* SoC temperature */}
        {typeof temperature === 'number' && (
          <div className="flex w-full items-center justify-between">
            <span>{t('settings.about.temperature')}</span>
            <span
              className={clsx(
                'tabular-nums',
                temperature >= TEMPERATURE_HOT
                  ? 'text-red-500'
                  : temperature >= TEMPERATURE_WARM && 'text-amber-500'
              )}
            >
              {temperature.toFixed(1)} °C
            </span>
          </div>
        )}

        {/* device number （product number） */}
        {!!information?.pn && (
          <div className="flex w-full items-center justify-between">
            <div className="flex items-center space-x-2">
              <span>{t('settings.about.device_number')}</span>
            </div>

            <span>
              {information.pn.trim() && information.pn.trim().toLowerCase() !== 'unknown'
                ? information.pn.trim()
                : 'Unknown'}
            </span>
          </div>
        )}
      </div>
    </>
  );
};
