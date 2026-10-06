// TODO: refactor it

// main keys
export const keyboardOptions = {
  theme: 'simple-keyboard hg-theme-default',
  baseClass: 'simple-keyboard-main',
  layout: {
    default: [
      '{escape} F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12',
      'Backquote Digit1 Digit2 Digit3 Digit4 Digit5 Digit6 Digit7 Digit8 Digit9 Digit0 Minus Equal {backspace}',
      '{tab} KeyQ KeyW KeyE KeyR KeyT KeyY KeyU KeyI KeyO KeyP BracketLeft BracketRight Backslash',
      '{capslock} KeyA KeyS KeyD KeyF KeyG KeyH KeyJ KeyK KeyL Semicolon Quote {enter}',
      '{shiftleft} KeyZ KeyX KeyC KeyV KeyB KeyN KeyM Comma Period Slash {shiftright}',
      '{controlleft} {winleft} {altleft} {space} {altright} {winright} {menu} {controlright}'
    ],
    mac: [
      '{escape} F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12',
      'Backquote Digit1 Digit2 Digit3 Digit4 Digit5 Digit6 Digit7 Digit8 Digit9 Digit0 Minus Equal {backspace}',
      '{tab} KeyQ KeyW KeyE KeyR KeyT KeyY KeyU KeyI KeyO KeyP BracketLeft BracketRight Backslash',
      '{capslock} KeyA KeyS KeyD KeyF KeyG KeyH KeyJ KeyK KeyL Semicolon Quote {enter}',
      '{shiftleft} KeyZ KeyX KeyC KeyV KeyB KeyN KeyM Comma Period Slash {shiftright}',
      '{controlleft} {altleft} {metaleft} {space} {metaright} {altright}'
    ],
    rus: [
      '{escape} F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12',
      'Backquote Digit1 Digit2 Digit3 Digit4 Digit5 Digit6 Digit7 Digit8 Digit9 Digit0 Minus Equal {backspace}',
      '{tab} RusQ RusW RusE RusR RusT RusY RusU RusI RusO RusP RusBracketLeft RusBracketRight RusBackslash',
      '{capslock} RusA RusS RusD RusF RusG RusH RusJ RusK RusL RusSemicolon RusQuote {enter}',
      '{shiftleft} RusZ RusX RusC RusV RusB RusN RusM RusComma RusPeriod RusSlash {shiftright}',
      '{controlleft} {winleft} {altleft} {space} {altright} {winright} {menu} {controlright}'
    ],
    azerty: [
      '{escape} F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12',
      'Backquote_azerty Digit1_azerty Digit2_azerty Digit3_azerty Digit4_azerty Digit5_azerty Digit6_azerty Digit7_azerty Digit8_azerty Digit9_azerty Digit0_azerty Minus_azerty Equal_azerty {backspace}',
      '{tab} KeyA_azerty KeyZ_azerty KeyE_azerty KeyR_azerty KeyT_azerty KeyY_azerty KeyU_azerty KeyI_azerty KeyO_azerty KeyP_azerty BracketLeft_azerty BracketRight_azerty Backslash_azerty',
      '{capslock} KeyQ_azerty KeyS_azerty KeyD_azerty KeyF_azerty KeyG_azerty KeyH_azerty KeyJ_azerty KeyK_azerty KeyL_azerty Semicolon_azerty Quote_azerty {enter}',
      '{shiftleft} KeyW_azerty KeyX_azerty KeyC_azerty KeyV_azerty KeyB_azerty KeyN_azerty KeyM_azerty Comma_azerty Period_azerty Slash_azerty {shiftright}',
      '{controlleft} {winleft} {altleft} {space} {altright} {winright} {menu} {controlright}'
    ]
  },
  display: {
    '{escape}': 'Esc',
    Backquote: '~<br/>`',
    Digit1: '!<br/>1',
    Digit2: '@<br/>2',
    Digit3: '#<br/>3',
    Digit4: '$<br/>4',
    Digit5: '%<br/>5',
    Digit6: '^<br/>6',
    Digit7: '&<br/>7',
    Digit8: '*<br/>8',
    Digit9: '(<br/>9',
    Digit0: ')<br/>0',
    Minus: '_<br/>-',
    Equal: '+<br/>=',
    '{backspace}': 'Backspace',

    '{tab}': 'Tab',
    KeyQ: 'Q',
    KeyW: 'W',
    KeyE: 'E',
    KeyR: 'R',
    KeyT: 'T',
    KeyY: 'Y',
    KeyU: 'U',
    KeyI: 'I',
    KeyO: 'O',
    KeyP: 'P',
    BracketLeft: '{<br/>[',
    BracketRight: '}<br/>]',
    Backslash: '|<br>\\',

    '{capslock}': 'Caps',
    KeyA: 'A',
    KeyS: 'S',
    KeyD: 'D',
    KeyF: 'F',
    KeyG: 'G',
    KeyH: 'H',
    KeyJ: 'J',
    KeyK: 'K',
    KeyL: 'L',
    Semicolon: ':<br/>;',
    Quote: '"<br/>\'',
    '{enter}': 'Enter',

    '{shiftleft}': 'Shift',
    KeyZ: 'Z',
    KeyX: 'X',
    KeyC: 'C',
    KeyV: 'V',
    KeyB: 'B',
    KeyN: 'N',
    KeyM: 'M',
    Comma: '<<br/>,',
    Period: '><br/>.',
    Slash: '?<br/>/',
    '{shiftright}': 'Shift',

    '{controlleft}': 'Ctrl',
    '{altleft}': 'Alt',
    '{metaleft}': 'Cmd',
    '{winleft}': 'Win',
    '{space}': 'Space',
    '{metaright}': 'Cmd',
    '{winright}': 'Win',
    '{altright}': 'Alt',
    '{menu}': 'Menu',
    '{controlright}': 'Ctrl',

    RusQ: 'Й',
    RusW: 'Ц',
    RusE: 'У',
    RusR: 'К',
    RusT: 'Е',
    RusY: 'Н',
    RusU: 'Г',
    RusI: 'Ш',
    RusO: 'Щ',
    RusP: 'З',
    RusBracketLeft: 'Х',
    RusBracketRight: 'Ъ',
    RusBackslash: '/<br>\\',

    RusA: 'Ф',
    RusS: 'Ы',
    RusD: 'В',
    RusF: 'А',
    RusG: 'П',
    RusH: 'Р',
    RusJ: 'О',
    RusK: 'Л',
    RusL: 'Д',
    RusSemicolon: 'Ж',
    RusQuote: 'Э',

    RusZ: 'Я',
    RusX: 'Ч',
    RusC: 'С',
    RusV: 'М',
    RusB: 'И',
    RusN: 'Т',
    RusM: 'Ь',
    RusComma: 'Б',
    RusPeriod: 'Ю',
    RusSlash: ',<br/>.',

    // AZERTY specific display keys
    // Row 1
    Backquote_azerty: '&#60;<br/>&#62;',
    Digit1_azerty: '&<br/>1',
    Digit2_azerty: 'é<br/>2',
    Digit3_azerty: '"<br/>#',
    Digit4_azerty: "'<br/>{",
    Digit5_azerty: '(<br/>[',
    Digit6_azerty: '-<br/>|',
    Digit7_azerty: 'è<br/>`',
    Digit8_azerty: '_<br/>\\',
    Digit9_azerty: 'ç<br/>^',
    Digit0_azerty: 'à<br/>@',
    Minus_azerty: ')<br/>]',
    Equal_azerty: '=<br/>}',

    // Row 2
    KeyA_azerty: 'A',
    KeyZ_azerty: 'Z',
    KeyE_azerty: 'E<br/>€',
    KeyR_azerty: 'R',
    KeyT_azerty: 'T',
    KeyY_azerty: 'Y',
    KeyU_azerty: 'U',
    KeyI_azerty: 'I',
    KeyO_azerty: 'O',
    KeyP_azerty: 'P',
    BracketLeft_azerty: '¨<br/>^',
    BracketRight_azerty: '£<br/>$',
    Backslash_azerty: 'µ<br/>*',

    // Row 3
    KeyQ_azerty: 'Q',
    KeyS_azerty: 'S',
    KeyD_azerty: 'D',
    KeyF_azerty: 'F',
    KeyG_azerty: 'G',
    KeyH_azerty: 'H',
    KeyJ_azerty: 'J',
    KeyK_azerty: 'K',
    KeyL_azerty: 'L',
    Semicolon_azerty: 'M',
    Quote_azerty: '%<br/>ù',

    // Row 4
    KeyW_azerty: 'W',
    KeyX_azerty: 'X',
    KeyC_azerty: 'C',
    KeyV_azerty: 'V',
    KeyB_azerty: 'B',
    KeyN_azerty: 'N',
    KeyM_azerty: '?<br/>,',
    Comma_azerty: '.<br/>;',
    Period_azerty: '/<br/>:',
    Slash_azerty: '§<br/>!'
  },
  // Enable layout-specific display
  mergeDisplay: true,
  layoutCandidates: {
    default: 'default',
    shift: 'shift',
    azerty: 'azerty'
  }
  // ...remaining options...
};

export const letterKeysMap: Record<string, { upper: string; lower: string }> = {
  KeyQ: { upper: 'Q', lower: 'q' },
  KeyW: { upper: 'W', lower: 'w' },
  KeyE: { upper: 'E', lower: 'e' },
  KeyR: { upper: 'R', lower: 'r' },
  KeyT: { upper: 'T', lower: 't' },
  KeyY: { upper: 'Y', lower: 'y' },
  KeyU: { upper: 'U', lower: 'u' },
  KeyI: { upper: 'I', lower: 'i' },
  KeyO: { upper: 'O', lower: 'o' },
  KeyP: { upper: 'P', lower: 'p' },
  KeyA: { upper: 'A', lower: 'a' },
  KeyS: { upper: 'S', lower: 's' },
  KeyD: { upper: 'D', lower: 'd' },
  KeyF: { upper: 'F', lower: 'f' },
  KeyG: { upper: 'G', lower: 'g' },
  KeyH: { upper: 'H', lower: 'h' },
  KeyJ: { upper: 'J', lower: 'j' },
  KeyK: { upper: 'K', lower: 'k' },
  KeyL: { upper: 'L', lower: 'l' },
  KeyZ: { upper: 'Z', lower: 'z' },
  KeyX: { upper: 'X', lower: 'x' },
  KeyC: { upper: 'C', lower: 'c' },
  KeyV: { upper: 'V', lower: 'v' },
  KeyB: { upper: 'B', lower: 'b' },
  KeyN: { upper: 'N', lower: 'n' },
  KeyM: { upper: 'M', lower: 'm' },

  // Russian letters
  RusQ: { upper: 'Й', lower: 'й' },
  RusW: { upper: 'Ц', lower: 'ц' },
  RusE: { upper: 'У', lower: 'у' },
  RusR: { upper: 'К', lower: 'к' },
  RusT: { upper: 'Е', lower: 'е' },
  RusY: { upper: 'Н', lower: 'н' },
  RusU: { upper: 'Г', lower: 'г' },
  RusI: { upper: 'Ш', lower: 'ш' },
  RusO: { upper: 'Щ', lower: 'щ' },
  RusP: { upper: 'З', lower: 'з' },
  RusBracketLeft: { upper: 'Х', lower: 'х' },
  RusBracketRight: { upper: 'Ъ', lower: 'ъ' },
  RusA: { upper: 'Ф', lower: 'ф' },
  RusS: { upper: 'Ы', lower: 'ы' },
  RusD: { upper: 'В', lower: 'в' },
  RusF: { upper: 'А', lower: 'а' },
  RusG: { upper: 'П', lower: 'п' },
  RusH: { upper: 'Р', lower: 'р' },
  RusJ: { upper: 'О', lower: 'о' },
  RusK: { upper: 'Л', lower: 'л' },
  RusL: { upper: 'Д', lower: 'д' },
  RusSemicolon: { upper: 'Ж', lower: 'ж' },
  RusQuote: { upper: 'Э', lower: 'э' },
  RusZ: { upper: 'Я', lower: 'я' },
  RusX: { upper: 'Ч', lower: 'ч' },
  RusC: { upper: 'С', lower: 'с' },
  RusV: { upper: 'М', lower: 'м' },
  RusB: { upper: 'И', lower: 'и' },
  RusN: { upper: 'Т', lower: 'т' },
  RusM: { upper: 'Ь', lower: 'ь' },
  RusComma: { upper: 'Б', lower: 'б' },
  RusPeriod: { upper: 'Ю', lower: 'ю' },

  // AZERTY letters
  KeyA_azerty: { upper: 'A', lower: 'a' },
  KeyZ_azerty: { upper: 'Z', lower: 'z' },
  KeyE_azerty: { upper: 'E<br/>€', lower: 'e<br/>€' },
  KeyR_azerty: { upper: 'R', lower: 'r' },
  KeyT_azerty: { upper: 'T', lower: 't' },
  KeyY_azerty: { upper: 'Y', lower: 'y' },
  KeyU_azerty: { upper: 'U', lower: 'u' },
  KeyI_azerty: { upper: 'I', lower: 'i' },
  KeyO_azerty: { upper: 'O', lower: 'o' },
  KeyP_azerty: { upper: 'P', lower: 'p' },
  KeyQ_azerty: { upper: 'Q', lower: 'q' },
  KeyS_azerty: { upper: 'S', lower: 's' },
  KeyD_azerty: { upper: 'D', lower: 'd' },
  KeyF_azerty: { upper: 'F', lower: 'f' },
  KeyG_azerty: { upper: 'G', lower: 'g' },
  KeyH_azerty: { upper: 'H', lower: 'h' },
  KeyJ_azerty: { upper: 'J', lower: 'j' },
  KeyK_azerty: { upper: 'K', lower: 'k' },
  KeyL_azerty: { upper: 'L', lower: 'l' },
  Semicolon_azerty: { upper: 'M', lower: 'm' },
  KeyW_azerty: { upper: 'W', lower: 'w' },
  KeyX_azerty: { upper: 'X', lower: 'x' },
  KeyC_azerty: { upper: 'C', lower: 'c' },
  KeyV_azerty: { upper: 'V', lower: 'v' },
  KeyB_azerty: { upper: 'B', lower: 'b' },
  KeyN_azerty: { upper: 'N', lower: 'n' }
};

export function getKeyboardDisplay(isUppercase: boolean): Record<string, string> {
  const display: Record<string, string> = { ...keyboardOptions.display };
  for (const [key, mapping] of Object.entries(letterKeysMap)) {
    display[key] = isUppercase ? mapping.upper : mapping.lower;
  }
  return display;
}

// control keys
export const keyboardControlPadOptions = {
  theme: 'simple-keyboard hg-theme-default',
  baseClass: 'simple-keyboard-control',
  layout: {
    default: [
      '{prtscr} {scrolllock} {pause}',
      '{insert} {home} {pageup}',
      '{delete} {end} {pagedown}'
    ]
  },

  display: {
    '{prtscr}': 'PrtScr',
    '{scrolllock}': 'Lock',
    '{pause}': 'Pause',
    '{insert}': 'Ins',
    '{home}': 'Home',
    '{pageup}': 'PgUp',
    '{delete}': 'Del',
    '{end}': 'End',
    '{pagedown}': 'PgDn'
  }
};

// arrow keys
export const keyboardArrowsOptions = {
  theme: 'simple-keyboard hg-theme-default',
  baseClass: 'simple-keyboard-arrows',
  layout: {
    default: ['{arrowup}', '{arrowleft} {arrowdown} {arrowright}']
  }
};

// keys require special mapping
export const specialKeyMap = new Map([
  ['{escape}', 'Escape'],
  ['{backspace}', 'Backspace'],
  ['{tab}', 'Tab'],
  ['{capslock}', 'CapsLock'],
  ['{enter}', 'Enter'],
  ['{shiftleft}', 'ShiftLeft'],
  ['{shiftright}', 'ShiftRight'],
  ['{controlleft}', 'ControlLeft'],
  ['{controlright}', 'ControlRight'],
  ['{altleft}', 'AltLeft'],
  ['{metaleft}', 'MetaLeft'],
  ['{winleft}', 'MetaLeft'],
  ['{space}', 'Space'],
  ['{metaright}', 'MetaRight'],
  ['{winright}', 'MetaRight'],
  ['{altright}', 'AltRight'],
  ['{prtscr}', 'PrintScreen'],
  ['{scrolllock}', 'ScrollLock'],
  ['{pause}', 'Pause'],
  ['{insert}', 'Insert'],
  ['{home}', 'Home'],
  ['{pageup}', 'PageUp'],
  ['{delete}', 'Delete'],
  ['{end}', 'End'],
  ['{pagedown}', 'PageDown'],
  ['{arrowright}', 'ArrowRight'],
  ['{arrowleft}', 'ArrowLeft'],
  ['{arrowdown}', 'ArrowDown'],
  ['{arrowup}', 'ArrowUp']
]);

// modifier keys
export const modifierKeys = [
  '{shiftleft}',
  '{controlleft}',
  '{altleft}',
  '{metaleft}',
  '{winleft}',
  '{shiftright}',
  '{controlright}',
  '{altright}',
  '{metaright}',
  '{winright}'
];

// double line display buttons
export const doubleKeys = [
  'Backquote',
  'Digit1',
  'Digit2',
  'Digit3',
  'Digit4',
  'Digit5',
  'Digit6',
  'Digit7',
  'Digit8',
  'Digit9',
  'Digit0',
  'Minus',
  'Equal',
  'BracketLeft',
  'BracketRight',
  'Backslash',
  'Semicolon',
  'Quote',
  'Comma',
  'Period',
  'Slash'
];
