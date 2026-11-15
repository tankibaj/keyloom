import type { ReactNode } from "react";
import { FONT_MONO, FONT_SANS, type Theme } from "../lib/theme";
import { Win } from "./Win";

const AGENT = ["✻ Reading src/checkout/totals.ts", "● Update(src/checkout/totals.ts)", "  ⎿ Updated with 12 additions, 3 removals"];

export const CARET = (on: boolean, T: Theme) => (
  <span style={{ display: "inline-block", width: 3, height: "1.05em", background: T.blue, verticalAlign: "text-bottom", marginLeft: 2, opacity: on ? 1 : 0 }} />
);

/** Terminal-style window with an agent prompt box (placeholder look, no vendor marks). Shows only the user's own prompts. */
export const TermWindow = ({ T, x, y, w, h, inputH, msgs, sentF, input, badge, scale = 1, opacity = 1, dy = 0, title = "web-app", agent = false }: {
  T: Theme; x: number; y: number; w: number; h: number; inputH: number; msgs: string[]; sentF: number; input: ReactNode; badge?: string; scale?: number; opacity?: number; dy?: number; title?: string; agent?: boolean;
}) => {
  const histH = h - 52 - inputH - (agent ? 64 : 36);
  return (
    <Win T={T} x={x} y={y} w={w} h={h} title={title} bg={T.term} scale={scale} opacity={opacity} dy={dy}
      titleRight={badge ? <div style={{ fontFamily: FONT_MONO, fontWeight: 500, fontSize: 18, color: T.red, background: "rgba(255,59,48,.12)", borderRadius: 10, padding: "3px 12px" }}>{badge}</div> : null}>
      <div style={{ position: "absolute", left: 28, right: 28, top: 0, height: histH, overflow: "hidden" }}>
        {agent && (
          <div style={{ position: "absolute", left: 0, top: 16, fontFamily: FONT_MONO, fontSize: 20, lineHeight: "32px", whiteSpace: "pre" }}>
            {AGENT.map((l, k) => <div key={k} style={{ color: l.startsWith("  ⎿") ? T.dim : l.startsWith("✻") ? "#c28a1c" : T.txt }}>{l}</div>)}
          </div>
        )}
        {msgs.map((m, k) => {
          const a = sentF - k;
          if (a <= 0) return null;
          const off = (sentF - 1 - k) * 46;
          return (
            <div key={k} style={{ position: "absolute", left: 0, right: 0, bottom: 6 + off, height: 40, lineHeight: "40px", fontFamily: FONT_MONO, fontSize: 19, color: T.dim, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", opacity: Math.min(1, a * 3) }}>
              <span style={{ color: T.dim, marginRight: 12 }}>&gt;</span>{m}
            </div>
          );
        })}
      </div>
      <div style={{ position: "absolute", left: 20, right: 20, bottom: agent ? 52 : 20, height: inputH, borderRadius: 14, background: T.termBox, border: `1.5px solid ${T.line}`, boxShadow: "inset 0 1px 2px rgba(0,0,0,.04)", boxSizing: "border-box", padding: "16px 22px", fontFamily: FONT_MONO, fontSize: 28, lineHeight: "42px", color: T.txt, display: "flex", gap: 16 }}>
        <span style={{ color: T.txt, fontWeight: 500 }}>&gt;</span>
        <div style={{ flex: 1, minWidth: 0, whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{input}</div>
      </div>
      {agent && <div style={{ position: "absolute", left: 30, bottom: 16, fontFamily: FONT_MONO, fontSize: 18, color: T.dim }}>? for shortcuts</div>}
    </Win>
  );
};
export { FONT_SANS };
