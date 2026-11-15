import { FONT_MONO, FONT_SANS, ACCENT, clamp01 } from "../lib/theme";
import { mix } from "../lib/anim";
import { shadowStack } from "./Win";

const rgb = (a: number[], b: number[], t: number) => `rgb(${a.map((v, i) => Math.round(mix(v, b[i], t))).join(",")})`;

/** The film's recurring device: times typed today. Screen-space overlay, top right. */
export const Counter = ({ value, pulse = 0, scale = 1, opacity = 1 }: { value: number; pulse?: number; scale?: number; opacity?: number }) => {
  const heat = clamp01((value - 1) / 39);
  const col = rgb([255, 59, 48], [255, 59, 48], heat);
  return (
    <div style={{ position: "absolute", right: 70, top: 44, width: 300, height: 170, opacity, transform: `scale(${scale * (1 + 0.06 * pulse)})`, transformOrigin: "100% 0", borderRadius: 30, background: "#ffffff", boxShadow: shadowStack(0.8, false), display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center" }}>
      <div style={{ fontFamily: FONT_SANS, fontWeight: 600, fontSize: 22, letterSpacing: "0.14em", color: "#8a8a8e" }}>TIMES TYPED</div>
      <div style={{ fontFamily: FONT_MONO, fontWeight: 500, fontSize: 112, lineHeight: 1.05, color: value < 1.5 ? ACCENT : col, letterSpacing: "-0.04em" }}>{Math.round(value)}</div>
    </div>
  );
};
