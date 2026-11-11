import { Image } from 'antd';
import clsx from 'clsx';
import { useAtomValue } from 'jotai';

import MonitorXIcon from '@/assets/images/monitor-x.svg';
import { getBaseUrl } from '@/lib/service.ts';
import { getVideoTransformStyle } from '@/lib/video-transform.ts';
import { mouseStyleAtom } from '@/jotai/mouse.ts';
import { videoParametersAtom } from '@/jotai/screen.ts';

export const Mjpeg = () => {
  const videoParameters = useAtomValue(videoParametersAtom);
  const mouseStyle = useAtomValue(mouseStyleAtom);

  return (
    <div className="flex h-full w-full items-center justify-center">
      <Image
        id="screen"
        className={clsx(
          'block max-h-full min-w-[50dvw] max-w-full select-none object-contain sm:min-h-[50dvh]',
          mouseStyle
        )}
        style={getVideoTransformStyle(videoParameters.scale, videoParameters.rotation)}
        src={`${getBaseUrl('http')}/api/stream/mjpeg`}
        fallback={MonitorXIcon}
        preview={false}
      />
    </div>
  );
};
