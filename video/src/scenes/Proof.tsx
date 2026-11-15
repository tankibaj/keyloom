import type { ReactNode } from "react";
import { FPS, easeIn, easeInOut, easeOut, mix, ramp, spr } from "../lib/anim";
import { DIFF, FONT_MONO, FONT_SANS, clamp01, type Theme } from "../lib/theme";
import { Keycap } from "../ui/Keycap";
import { Win, Lights } from "../ui/Win";
import { CARET, TermWindow } from "../ui/Term";

// Stage-space layout (shared with the leader-line infographic)
export const TERM = { x: 740, y: 110, w: 1080, h: 620, inputH: 340 };
export const DIFFW = { x: 200, y: 230, w: 480, h: 250 };
const IN_TOP = TERM.y + TERM.h - 20 - TERM.inputH + 16; // first text line top inside the prompt box
export const LINE_H = 40;
export const TEXT_X = TERM.x + 20 + 22 + 16 + 14;

export const KW = "::review";
const T_KEY0 = 14.8, KEY_GAP = 0.26, T_VANISH = T_KEY0 + KEY_GAP * 7 + 0.02;
const FILL = { l0: 16.75, l1: 17.05, scope: 17.35, d: [17.85, 18.05, 18.25, 18.45] };

const lineStyle = (frame: number, at: number, dur = 0.32) => {
  const p = ramp(frame, at, at + dur, easeOut);
  return { clipPath: `inset(0 ${(1 - p) * 100}% 0 0)`, opacity: p > 0 ? 1 : 0, transform: `translateY(${(1 - p) * 6}px)` } as const;
};

/** Proof stage: template card, copied diff, terminal prompt box, argument panel, leader lines. */
export const Proof = ({ frame, T, enter }: { frame: number; T: Theme; enter: number }) => {
  const t = frame / FPS;
  const e = (d: number) => spr(frame, 13.5 + d, 0.8);
  const dark = T.win === "#1e1e1e";

  // typing the keyword, vanishing at the final character (no Tab, no Return)
  const nKeys = clamp01(0) + Math.max(0, Math.min(8, Math.floor((t - T_KEY0) / KEY_GAP) + 1));
  const typedKw = t < T_VANISH ? KW.slice(0, nKeys) : "";
  const filled = t >= FILL.l0;
  const caretOn = (t >= T_KEY0 && t < T_VANISH) || Math.floor(t * 2.4) % 2 === 0;

  const rows: ReactNode[] = [];
  const L = (i: number, at: number, node: ReactNode, mono = false) =>
    rows.push(<div key={i} style={{ position: "absolute", left: 0, top: i * LINE_H, height: LINE_H, lineHeight: `${LINE_H}px`, whiteSpace: "nowrap", fontFamily: mono ? FONT_MONO : FONT_MONO, fontSize: 22, ...lineStyle(frame, at) }}>{node}</div>);
  if (filled) {
    L(0, FILL.l0, "Review the change below against the plan.");
    L(1, FILL.l1, "List bugs first, then risks, then nits.");
    L(2, FILL.scope, "Scope: the whole diff");
    DIFF.forEach((d, i) => L(4 + i, FILL.d[i], d));
  }
  const input = (
    <div style={{ position: "relative", height: "100%" }}>
      {!filled && (typedKw || t >= 14.5 ? <span>{typedKw}{CARET(caretOn, T)}</span> : <span style={{ color: T.dim }}>{CARET(caretOn, T)}Message the agent…</span>)}
      {filled && <div style={{ position: "absolute", left: 0, top: 0, right: 0 }}>{rows}</div>}
    </div>
  );

  // copy sweep over the diff
  const sweep = ramp(frame, 13.7, 14.0, easeInOut);
  const kc = spr(frame, 13.7, 0.5, { damping: 14, stiffness: 160 });
  const kcPress = ramp(frame, 14.05, 14.13, (x) => x) * (1 - ramp(frame, 14.25, 14.4, (x) => x));
  const kcOut = 1 - ramp(frame, 14.55, 14.8, easeIn);
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      <TermWindow T={T} x={TERM.x} y={TERM.y} w={TERM.w} h={TERM.h} inputH={TERM.inputH} msgs={[]} sentF={0} input={input} opacity={Math.min(1, e(0) * 1.5)} dy={(1 - e(0)) * 60} title="zsh · agent 1" agent />
      {/* diff window */}
      <Win T={T} x={DIFFW.x} y={DIFFW.y} w={DIFFW.w} h={DIFFW.h} title="Diff" opacity={Math.min(1, e(0.24) * 1.5)} dy={(1 - e(0.24)) * 60}>
        <div style={{ padding: "18px 22px", position: "relative" }}>
          <div style={{ position: "absolute", left: 14, top: 18, width: (DIFFW.w - 28) * sweep, height: 4 * 38, borderRadius: 8, background: T.sel }} />
          {DIFF.map((d, i) => (
            <div key={i} style={{ position: "relative", height: 38, lineHeight: "38px", fontFamily: FONT_MONO, fontSize: 19, color: d[0] === "-" ? T.red : T.green, whiteSpace: "nowrap" }}>{d}</div>
          ))}
        </div>
      </Win>
      <div style={{ position: "absolute", left: DIFFW.x + 120, top: DIFFW.y + DIFFW.h + 24, display: "flex", gap: 12, opacity: kcOut * Math.min(1, kc * 2), transform: `scale(${0.72 * mix(0.6, 1, kc)})`, transformOrigin: "0 0" }}>
        <Keycap label="⌘" pressed={kcPress} dark={dark} /><Keycap label="C" pressed={kcPress} dark={dark} />
      </div>
    </div>
  );
};
export { Lights };
