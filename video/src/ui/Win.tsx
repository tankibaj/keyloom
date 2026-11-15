import type { CSSProperties, ReactNode } from "react";
import { FONT_SANS, type Theme } from "../lib/theme";

export const TITLE_H = 52;
export const shadowStack = (k: number, dark: boolean) =>
  `0 ${48 * k}px ${96 * k}px rgba(0,0,0,${(dark ? 0.55 : 0.20) * k}), 0 ${14 * k}px ${30 * k}px rgba(0,0,0,${(dark ? 0.4 : 0.12) * k}), 0 2px 5px rgba(0,0,0,${0.10 * k}), 0 0 0 1px ${dark ? "rgba(255,255,255,.07)" : "rgba(0,0,0,.07)"}`;

export const Lights = ({ active = true }: { active?: boolean }) => (
  <div style={{ display: "flex", gap: 9 }}>
    {["#ff5f57", "#febc2e", "#28c840"].map((c, i) => (
      <div key={i} style={{ width: 15, height: 15, borderRadius: 8, background: active ? c : "#c9c9ce" }} />
    ))}
  </div>
);

/** Generic window chrome (placeholder style, no OS trade dress). x,y,w,h are the unscaled box; scale is about the centre. */
export const Win = ({ T, x, y, w, h, title, children, scale = 1, opacity = 1, dy = 0, titleRight, bg, style }: {
  T: Theme; x: number; y: number; w: number; h: number; title: string; children: ReactNode; scale?: number; opacity?: number; dy?: number; titleRight?: ReactNode; bg?: string; style?: CSSProperties;
}) => (
  <div style={{ position: "absolute", left: x, top: y + dy, width: w, height: h, opacity, transform: `scale(${scale})`, ...style }}>
    <div style={{ position: "absolute", inset: 0, borderRadius: 16, background: bg ?? T.win, boxShadow: shadowStack(1, T.win === "#1e1e1e"), overflow: "hidden" }}>
      <div style={{ height: TITLE_H, display: "flex", alignItems: "center", padding: "0 20px", borderBottom: `1px solid ${T.line}`, position: "relative" }}>
        <Lights />
        <div style={{ position: "absolute", left: 0, right: 0, textAlign: "center", fontFamily: FONT_SANS, fontWeight: 600, fontSize: 18, color: T.dim }}>{title}</div>
        <div style={{ marginLeft: "auto" }}>{titleRight}</div>
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: TITLE_H, bottom: 0 }}>{children}</div>
    </div>
  </div>
);
