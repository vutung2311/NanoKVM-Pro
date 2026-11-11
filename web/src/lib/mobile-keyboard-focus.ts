type KeyboardController = {
  focus: () => void;
  blur: () => void;
  toggle: () => void;
};

let controller: KeyboardController | null = null;

export function registerMobileKeyboardController(next: KeyboardController): () => void {
  controller = next;
  return () => {
    if (controller === next) {
      controller = null;
    }
  };
}

export function focusMobileKeyboard(): boolean {
  if (!controller) return false;
  controller.focus();
  return true;
}

export function blurMobileKeyboard(): boolean {
  if (!controller) return false;
  controller.blur();
  return true;
}

export function toggleMobileKeyboard(): boolean {
  if (!controller) return false;
  controller.toggle();
  return true;
}
