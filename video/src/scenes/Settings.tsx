import type { ReactNode } from "react";
import { easeInOut, mix, ramp, spr } from "../lib/anim";
import { FONT_MONO, FONT_SANS, type Theme } from "../lib/theme";
import { Win } from "../ui/Win";

export const SET = { x: 530, y: 100, w: 860, h: 540 };
export const SEG = { x: SET.x + SET.w - 40 - 18 - 330, y: SET.y + 52 + 146 + 36, cell: 110 };
export const DARK_PT = { x: SEG.x + SEG.cell * 2.5, y: SEG.y };
export const T_IN = 21.2, T_CLICK = 21.8;

const Tab = ({ T, label, active }: { T: Theme; label: string; active?: boolean }) => (
  <div style={{ width: 150, height: 66, borderRadius: 12, background: active ? T.field : "transparent", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 6, fontFamily: FONT_SANS, fontWeight: 500, fontSize: 15, color: active ? T.blue : T.dim }}>
    <div style={{ width: 24, height: 20, borderRadius: 6, border: `2px solid ${active ? T.blue : T.dim}` }} />{label}
  </div>
);

const Card = ({ T, top, h, children }: { T: Theme; top: number; h: number; children: ReactNode }) => (
  <div style={{ position: "absolute", left: 40, right: 40, top, height: h, borderRadius: 16, background: T.field }}>{children}</div>
);

export const Settings = ({ frame, T }: { frame: number; T: Theme }) => {
  const p = spr(frame, T_IN, 0.7, { damping: 22, stiffness: 120 });
  const slide = ramp(frame, T_CLICK, T_CLICK + 0.4, easeInOut);
  if (p <= 0.001) return null;
  return (
    <Win T={T} x={SET.x} y={SET.y} w={SET.w} h={SET.h} title="General" opacity={Math.min(1, p * 1.8)} dy={(1 - p) * 70} scale={mix(0.92, 1, p)}>
      <div style={{ display: "flex", justifyContent: "center", gap: 8, paddingTop: 12 }}>
        <Tab T={T} label="General" active /><Tab T={T} label="Expansion" /><Tab T={T} label="Sync & Backups" />
      </div>
      <div style={{ position: "absolute", left: 40, top: 100, fontFamily: FONT_SANS, fontWeight: 700, fontSize: 22, color: T.txt }}>Appearance</div>
      <Card T={T} top={146} h={72}>
        <div style={{ position: "absolute", left: 22, top: 0, height: 72, display: "flex", alignItems: "center", fontFamily: FONT_SANS, fontSize: 21, color: T.txt }}>Appearance</div>
        <div style={{ position: "absolute", right: 18, top: 14, width: 330, height: 44, borderRadius: 11, background: T.btn }}>
          <div style={{ position: "absolute", top: 3, bottom: 3, left: 3 + SEG.cell * 2 * slide, width: SEG.cell - 6, borderRadius: 9, background: T.blue, boxShadow: "0 3px 8px rgba(0,122,255,.4)" }} />
          {["Auto", "Light", "Dark"].map((l, i) => {
            const sel = Math.abs(i - 2 * slide) < 0.5;
            return <div key={l} style={{ position: "absolute", left: SEG.cell * i, width: SEG.cell, top: 0, height: 44, display: "grid", placeItems: "center", fontFamily: FONT_SANS, fontWeight: 500, fontSize: 20, color: sel ? "#fff" : T.txt }}>{l}</div>;
          })}
        </div>
      </Card>
      <div style={{ position: "absolute", left: 40, top: 262, fontFamily: FONT_SANS, fontWeight: 700, fontSize: 22, color: T.txt }}>Quick Picker</div>
      <Card T={T} top={296} h={150}>
        <div style={{ position: "absolute", left: 22, top: 0, height: 74, display: "flex", alignItems: "center", fontFamily: FONT_SANS, fontSize: 21, color: T.txt }}>Shortcut</div>
        <div style={{ position: "absolute", right: 18, top: 15, height: 44, padding: "0 20px", borderRadius: 11, background: T.btn, display: "flex", alignItems: "center", fontFamily: FONT_MONO, fontSize: 20, color: T.txt }}>⌃⌥Space</div>
        <div style={{ position: "absolute", left: 22, top: 88, height: 44, padding: "0 20px", borderRadius: 11, background: T.btn, display: "flex", alignItems: "center", fontFamily: FONT_SANS, fontSize: 19, color: T.txt }}>Reset to Control-Option-Space</div>
      </Card>
    </Win>
  );
};
