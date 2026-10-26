import { test } from "node:test";
import assert from "node:assert/strict";
import { BBC, KeyboardTranslator } from "../src/keys.ts";

const press = (code: string, key: string, extra = {}) => ({ code, key, ctrlKey: false, repeat: false, ...extra });

test("by layout, Shift is pressed or released as each character needs", () => {
  const t = new KeyboardTranslator("layout");
  // US Shift-= types "+", which is Shift-; on a BBC.
  assert.deepEqual(t.keyDown(press("ShiftLeft", "Shift")), [{ code: BBC.shift, down: true }]);
  assert.deepEqual(t.keyDown(press("Equal", "+")), [{ code: BBC.shift, down: true }, { code: BBC.semicolon, down: true }]);
  assert.deepEqual(t.keyUp({ code: "Equal" }), [{ code: BBC.semicolon, down: false }, { code: BBC.shift, down: true }]);
  // US Shift-; types ":", unshifted on a BBC.
  assert.deepEqual(t.keyDown(press("Semicolon", ":")), [{ code: BBC.shift, down: false }, { code: BBC.colon, down: true }]);
  assert.deepEqual(t.keyUp({ code: "Semicolon" }), [{ code: BBC.colon, down: false }, { code: BBC.shift, down: true }]);
  assert.deepEqual(t.keyUp({ code: "ShiftLeft" }), [{ code: BBC.shift, down: false }]);
  // Letters follow Shift.
  assert.deepEqual(t.keyDown(press("KeyA", "a")), [{ code: BBC.a, down: true }]);
  assert.deepEqual(t.keyDown(press("KeyA", "a", { repeat: true })), []);
  assert.deepEqual(t.keyUp({ code: "KeyA" }), [{ code: BBC.a, down: false }]);
  // Keys that don't type go by position.
  assert.deepEqual(t.keyDown(press("Enter", "Enter")), [{ code: BBC.returnKey, down: true }]);
  assert.deepEqual(t.keyDown(press("F12", "F12")), [{ code: BBC.breakKey, down: true }]);
});

test("by position, keys are where they are on a BBC", () => {
  const t = new KeyboardTranslator("positional");
  assert.deepEqual(t.keyDown(press("Equal", "+")), [{ code: BBC.caret, down: true }]);
  assert.deepEqual(t.keyDown(press("Quote", "'")), [{ code: BBC.colon, down: true }]);
  assert.deepEqual(t.keyUp({ code: "Quote" }), [{ code: BBC.colon, down: false }]);
  assert.deepEqual(t.keyUp({ code: "Nothing" }), []);
});
