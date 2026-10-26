// The BBC keyboard matrix (row << 4 | column, as BeebCore's BeebKey has
// them), and how the host's keys press them: KeyboardTranslator, after
// BeebHost's (the Mac app's), either by position (a key is where it is on
// a BBC: Shift-8 types "(") or by the characters the host's layout types
// (Shift-8 types "*"), pressing or releasing the BBC's Shift as each key
// needs.

export const BBC = {
  space: 0x62, comma: 0x66, minus: 0x17, stop: 0x67, slash: 0x68,
  digit0: 0x27, digit1: 0x30, digit2: 0x31, digit3: 0x11, digit4: 0x12, digit5: 0x13, digit6: 0x34,
  digit7: 0x24, digit8: 0x15, digit9: 0x26,
  colon: 0x48, semicolon: 0x57, at: 0x47,
  a: 0x41, b: 0x64, c: 0x52, d: 0x32, e: 0x22, f: 0x43, g: 0x53, h: 0x54, i: 0x25, j: 0x45, k: 0x46, l: 0x56,
  m: 0x65, n: 0x55, o: 0x36, p: 0x37, q: 0x10, r: 0x33, s: 0x51, t: 0x23, u: 0x35, v: 0x63, w: 0x21, x: 0x42,
  y: 0x44, z: 0x61,
  leftSquareBracket: 0x38, backslash: 0x78, rightSquareBracket: 0x58, caret: 0x18, underline: 0x28,
  escape: 0x70, tab: 0x60, capsLock: 0x40, ctrl: 0x01, shiftLock: 0x50, shift: 0x00, delete: 0x59, copy: 0x69,
  returnKey: 0x49, up: 0x39, down: 0x29, left: 0x19, right: 0x79,
  f0: 0x20, f1: 0x71, f2: 0x72, f3: 0x73, f4: 0x14, f5: 0x74, f6: 0x75, f7: 0x16, f8: 0x76, f9: 0x77,
  keypad0: 0x6a, keypad1: 0x6b, keypad2: 0x7c, keypad3: 0x6c, keypad4: 0x7a, keypad5: 0x7b, keypad6: 0x1a,
  keypad7: 0x1b, keypad8: 0x2a, keypad9: 0x2b, keypadHash: 0x5a, keypadStar: 0x5b, keypadComma: 0x5c,
  keypadSlash: 0x4a, keypadDelete: 0x4b, keypadStop: 0x4c, keypadPlus: 0x3a, keypadMinus: 0x3b, keypadReturn: 0x3c,
  breakKey: 0x7f,
} as const;

const letters = "abcdefghijklmnopqrstuvwxyz";

/** KeyboardEvent.code to BBC key, by position. */
export const keyMap: Record<string, number> = {
  ...Object.fromEntries([...letters].map((l) => [`Key${l.toUpperCase()}`, BBC[l as keyof typeof BBC]])),
  Digit0: BBC.digit0, Digit1: BBC.digit1, Digit2: BBC.digit2, Digit3: BBC.digit3, Digit4: BBC.digit4,
  Digit5: BBC.digit5, Digit6: BBC.digit6, Digit7: BBC.digit7, Digit8: BBC.digit8, Digit9: BBC.digit9,
  // The number row goes on as the BBC's does: - ^ \.
  Minus: BBC.minus, Equal: BBC.caret, IntlYen: BBC.backslash,
  // QWERTY row: ... P @ [ (and _ £ beyond).
  BracketLeft: BBC.at, BracketRight: BBC.leftSquareBracket,
  // ASDF row: ... L ; : ].
  Semicolon: BBC.semicolon, Quote: BBC.colon, Backslash: BBC.rightSquareBracket, IntlHash: BBC.rightSquareBracket,
  Backquote: BBC.underline, IntlBackslash: BBC.backslash,
  Comma: BBC.comma, Period: BBC.stop, Slash: BBC.slash, Space: BBC.space,
  Enter: BBC.returnKey, NumpadEnter: BBC.returnKey, Backspace: BBC.delete, Delete: BBC.delete, End: BBC.copy,
  Escape: BBC.escape, Tab: BBC.tab, CapsLock: BBC.capsLock,
  ShiftLeft: BBC.shift, ShiftRight: BBC.shift, ControlLeft: BBC.ctrl, ControlRight: BBC.ctrl,
  AltLeft: BBC.shiftLock,
  ArrowUp: BBC.up, ArrowDown: BBC.down, ArrowLeft: BBC.left, ArrowRight: BBC.right,
  F10: BBC.f0, F1: BBC.f1, F2: BBC.f2, F3: BBC.f3, F4: BBC.f4, F5: BBC.f5, F6: BBC.f6, F7: BBC.f7, F8: BBC.f8,
  F9: BBC.f9, F12: BBC.breakKey,
  Numpad0: BBC.keypad0, Numpad1: BBC.keypad1, Numpad2: BBC.keypad2, Numpad3: BBC.keypad3, Numpad4: BBC.keypad4,
  Numpad5: BBC.keypad5, Numpad6: BBC.keypad6, Numpad7: BBC.keypad7, Numpad8: BBC.keypad8, Numpad9: BBC.keypad9,
  NumpadAdd: BBC.keypadPlus, NumpadSubtract: BBC.keypadMinus, NumpadMultiply: BBC.keypadStar,
  NumpadDivide: BBC.keypadSlash, NumpadDecimal: BBC.keypadStop, NumpadComma: BBC.keypadComma,
};

const letterKeys = [...letters].map((l) => BBC[l as keyof typeof BBC]);
const digitKeys = [BBC.digit1, BBC.digit2, BBC.digit3, BBC.digit4, BBC.digit5, BBC.digit6, BBC.digit7, BBC.digit8, BBC.digit9];
/** Characters to the key and Shift that type them on a UK BBC (BeebKey.forCharacter). */
const symbols: Record<string, [number, boolean]> = {
  " ": [BBC.space, false], "!": [BBC.digit1, true], '"': [BBC.digit2, true], "#": [BBC.digit3, true],
  $: [BBC.digit4, true], "%": [BBC.digit5, true], "&": [BBC.digit6, true], "'": [BBC.digit7, true],
  "(": [BBC.digit8, true], ")": [BBC.digit9, true], "*": [BBC.colon, true], "+": [BBC.semicolon, true],
  ",": [BBC.comma, false], "-": [BBC.minus, false], ".": [BBC.stop, false], "/": [BBC.slash, false],
  ":": [BBC.colon, false], ";": [BBC.semicolon, false], "<": [BBC.comma, true], "=": [BBC.minus, true],
  ">": [BBC.stop, true], "?": [BBC.slash, true], "@": [BBC.at, false], "[": [BBC.leftSquareBracket, false],
  "\\": [BBC.backslash, false], "]": [BBC.rightSquareBracket, false], "^": [BBC.caret, false],
  _: [BBC.underline, false], "`": [BBC.underline, true], "£": [BBC.underline, true],
  "{": [BBC.leftSquareBracket, true], "|": [BBC.backslash, true], "}": [BBC.rightSquareBracket, true],
  "~": [BBC.caret, true],
};

export function forCharacter(character: string): [number, boolean] | null {
  const c = character.charCodeAt(0);
  if (character.length !== 1) return null;
  if (c >= 0x61 && c <= 0x7a) return [letterKeys[c - 0x61], false];
  if (c >= 0x41 && c <= 0x5a) return [letterKeys[c - 0x41], true];
  if (character === "0") return [BBC.digit0, false];
  if (c >= 0x31 && c <= 0x39) return [digitKeys[c - 0x31], false];
  return symbols[character] ?? null;
}

/** Keys that type characters (so the layout decides what they type). */
const characterKey = /^(Key[A-Z]|Digit[0-9]|Minus|Equal|BracketLeft|BracketRight|Semicolon|Quote|Backquote|Backslash|IntlBackslash|IntlHash|IntlYen|Comma|Period|Slash)$/;

export type KeyboardMode = "layout" | "positional";
export type KeyAction = { code: number; down: boolean };

/** Host key events to BBC key presses, tracking what's held so releases match presses. */
export class KeyboardTranslator {
  mode: KeyboardMode;
  /** BBC keys held, by host key (KeyboardEvent.code), and the Shift each forces. */
  private held = new Map<string, { key: number; shift: boolean | null }>();
  private hostShift = false;

  constructor(mode: KeyboardMode = "layout") {
    this.mode = mode;
  }

  /** The BBC key a press of `event` means, and the Shift it needs (null: as held). */
  translate(event: { code: string; key: string; ctrlKey: boolean }): { key: number; shift: boolean | null } | null {
    if (this.mode === "layout" && !event.ctrlKey && characterKey.test(event.code)) {
      const typed = forCharacter(event.key);
      // Letters follow Shift and Caps Lock, as on both machines.
      if (typed) return { key: typed[0], shift: /[a-z]/i.test(event.key) ? null : typed[1] };
    }
    const key = keyMap[event.code];
    return key === undefined ? null : { key, shift: null };
  }

  keyDown(event: { code: string; key: string; ctrlKey: boolean; repeat: boolean }): KeyAction[] {
    // The BBC does its own auto-repeat.
    if (event.repeat || this.held.has(event.code)) return [];
    const translated = this.translate(event);
    if (!translated) return [];
    if (translated.key === BBC.shift) {
      this.hostShift = true;
      this.held.set(event.code, translated);
      return [...this.held.values()].some((h) => h.shift !== null) ? [] : [{ code: BBC.shift, down: true }];
    }
    this.held.set(event.code, translated);
    const actions: KeyAction[] = [];
    if (translated.shift !== null) actions.push({ code: BBC.shift, down: translated.shift });
    actions.push({ code: translated.key, down: true });
    return actions;
  }

  keyUp(event: { code: string }): KeyAction[] {
    const held = this.held.get(event.code);
    if (!held) return [];
    this.held.delete(event.code);
    if (held.key === BBC.shift) {
      this.hostShift = [...this.held.values()].some((h) => h.key === BBC.shift);
      return [...this.held.values()].some((h) => h.shift !== null) ? [] : [{ code: BBC.shift, down: this.hostShift }];
    }
    const actions: KeyAction[] = [{ code: held.key, down: false }];
    if (held.shift !== null) actions.push({ code: BBC.shift, down: this.currentShift });
    return actions;
  }

  /** Forget everything held (the machine releases its keys separately). */
  reset() {
    this.held.clear();
    this.hostShift = false;
  }

  get holding(): boolean {
    return this.held.size > 0;
  }

  /** Shift as the BBC should see it now: the last held override, or the host's. */
  private get currentShift(): boolean {
    const overrides = [...this.held.values()].map((h) => h.shift).filter((s) => s !== null);
    return overrides.length ? overrides[overrides.length - 1]! : this.hostShift;
  }
}
