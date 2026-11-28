import { describe, expect, test } from "bun:test";
import { subagentTitle } from "../src/agents/antigravity";
import { mailWake } from "../src/hooks/service";
import { parseSession } from "../src/muscu/service";
import { relayConfirmationTitle } from "../src/relay/whitelist";
import { goalConfirmation } from "../src/runner/goal";
import { preview } from "../src/store/store";
import { head, safeCut, tail } from "../src/text";

// The apps decode with JSONDecoder, which rejects a lone surrogate: every cut text must stay well formed.
const RUNNER = "🏃";
/** `length` characters of realistic French text, so that the runner emoji placed after it straddles a cut there. */
const lead = (length: number) => "Sortie Z2 de 45 min sous 145 bpm, retour au calme de 5 min. ".repeat(80).slice(0, length);

describe("cutting text for the apps", () => {
  test("safeCut moves back only from between the two halves of a pair", () => {
    const text = `Séance ${RUNNER} faite`;
    const between = text.indexOf(RUNNER) + 1;
    expect(safeCut(text, between)).toBe(between - 1);
    expect(safeCut(text, between + 1)).toBe(between + 1);
    expect(safeCut(text, 0)).toBe(0);
    expect(safeCut(text, text.length)).toBe(text.length);
  });

  test("head and tail keep the emoji whole or leave it out", () => {
    const text = `Séance ${RUNNER} faite`;
    const at = text.indexOf(RUNNER);
    expect(head(text, at + 1)).toBe("Séance ");
    expect(head(text, at + 2)).toBe(`Séance ${RUNNER}`);
    expect(tail(text, text.length - at - 1)).toBe(" faite");
    expect(tail(text, text.length - at)).toBe(`${RUNNER} faite`);
    expect(head(text, 100)).toBe(text);
    expect(tail(text, 0)).toBe("");
  });

  test("the preview of a last answer or a push", () => {
    const shown = preview(`${lead(118)}${RUNNER} à mardi`, 120);
    expect(shown).toBe(`${lead(118)}…`);
    expect(shown.isWellFormed()).toBe(true);
  });

  test("the subject and text of a woken bot's mail card", () => {
    const wake = mailWake(
      { to: "coach@bots.example", from: "julie.martin@lumen.example", fromName: "Julie Martin", subject: `${lead(298)}${RUNNER} demain`, text: `${lead(3998)}${RUNNER} à bientôt`, attachments: [] },
      true,
    ) as { subject: string; text: string };
    expect(wake.subject).toBe(`${lead(298)}…`);
    expect(wake.text).toBe(`${lead(3998)}…`);
    expect(wake.subject.isWellFormed() && wake.text.isWellFormed()).toBe(true);
  });

  test("an Antigravity subagent title", () => {
    const title = subagentTitle("invoke_subagent", { TaskName: `${lead(76)}${RUNNER} et récapitule` });
    expect(title).toBe(`${lead(76)}…`);
    expect(title.isWellFormed()).toBe(true);
  });

  test("the confirmation asked for a goal turn's action", () => {
    const title = goalConfirmation("apple_event_delete", { title: `${lead(78)}${RUNNER} jeudi` })!;
    expect(title).toBe(`Delete the event "${lead(78).trimEnd()}…"`);
    expect(title.isWellFormed()).toBe(true);
  });

  test("the confirmation asked for a relayed action", () => {
    const title = relayConfirmationTitle({ server: "nuo", name: "reminder_done", input: { title: `${lead(88)}${RUNNER} ce soir` } }, "fr");
    expect(title).toBe(`Cocher le rappel « ${lead(88).trimEnd()}… »`);
    expect(title.isWellFormed()).toBe(true);
  });

  test("the names and notes of a gym session", () => {
    const name = `${"Développé couché à la machine guidée, prise large et tempo 3-1-1".slice(0, 59)}${RUNNER}`;
    const session = parseSession({
      id: 7,
      name: "Haut du corps",
      config_json: JSON.stringify({ blocks: [{ exercises: [{ name, reps: 10, alts: [name] }], note: `${lead(199)}${RUNNER} récup 90 s` }] }),
      note: null,
    })!;
    const block = session.blocks[0]!;
    expect(block.exercises[0]!.name).toBe(name.slice(0, 59));
    expect(block.exercises[0]!.alts).toEqual([name.slice(0, 59)]);
    expect(block.note).toBe(lead(199));
    expect(JSON.stringify(block).isWellFormed() && block.note!.isWellFormed()).toBe(true);
  });
});
