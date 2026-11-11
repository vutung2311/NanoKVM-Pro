import { RefObject, useCallback, useEffect, useState } from 'react';
import { useAtomValue } from 'jotai';

import { menuDisabledItemsAtom } from '@/jotai/settings.ts';

export interface MenuBounds {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

export function useMenuBounds(
  nodeRef: RefObject<HTMLDivElement | null>,
  isMenuExpanded: boolean
): MenuBounds {
  const menuDisabledItems = useAtomValue(menuDisabledItemsAtom);
  const [menuBounds, setMenuBounds] = useState<MenuBounds>({
    left: 0,
    right: 0,
    top: 0,
    bottom: 0
  });

  const handleResize = useCallback(() => {
    if (!nodeRef.current) return;

    const elementRect = nodeRef.current.getBoundingClientRect();
    const viewportWidth = window.visualViewport?.width ?? window.innerWidth;
    const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
    const width = Math.max(0, (viewportWidth - elementRect.width) / 2);

    setMenuBounds({
      left: -width,
      top: -10,
      right: width,
      bottom: Math.max(0, viewportHeight - elementRect.height - 10)
    });
  }, [nodeRef]);

  // Update bounds on mount and resize
  useEffect(() => {
    const vv = window.visualViewport;
    handleResize();
    window.addEventListener('resize', handleResize);
    vv?.addEventListener('resize', handleResize);

    return () => {
      window.removeEventListener('resize', handleResize);
      vv?.removeEventListener('resize', handleResize);
    };
  }, [handleResize]);

  // Update bounds when menu items or expansion state change
  useEffect(() => {
    handleResize();
  }, [menuDisabledItems, isMenuExpanded, handleResize]);

  return menuBounds;
}
