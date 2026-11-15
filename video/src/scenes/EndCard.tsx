import { FONT_MONO, FONT_SANS, light as T } from "../lib/theme";
import { easeOut, ramp } from "../lib/anim";
import { KeyloomIcon } from "../ui/Icon";

const T0 = 23.4;
export const EndCard = ({ frame }: { frame: number }) => {
  const a = ramp(frame, T0 + 0.1, T0 + 0.8), b = ramp(frame, T0 + 0.35, T0 + 0.9), c = ramp(frame, T0 + 0.6, T0 + 1.15), d = ramp(frame, T0 + 0.9, T0 + 1.5);
  const up = (p: number, px: number) => `translateY(${(1 - p) * px}px)`;
  return (
    <div style={{ position: "absolute", inset: 0, fontFamily: FONT_SANS, color: T.txt, textAlign: "center" }}>
      <div style={{ position: "absolute", top: 78, left: 0, right: 0, display: "flex", justifyContent: "center", opacity: a, transform: `scale(${0.88 + 0.12 * easeOut(a)})` }}><KeyloomIcon size={160} /></div>
      <div style={{ position: "absolute", top: 262, left: 0, right: 0, fontWeight: 700, fontSize: 140, letterSpacing: "-0.045em", opacity: b, transform: up(b, 22) }}>Keyloom</div>
      <div style={{ position: "absolute", top: 424, left: 0, right: 0, fontWeight: 600, fontSize: 92, letterSpacing: "-0.035em", opacity: c, transform: up(c, 18) }}>Type it <span style={{ color: T.blue }}>once.</span></div>
      <div style={{ position: "absolute", top: 548, left: 0, right: 0, fontWeight: 500, fontSize: 38, color: T.dim, opacity: c }}>macOS · open source</div>
      <div style={{ position: "absolute", top: 700, left: 0, right: 0, fontFamily: FONT_MONO, fontWeight: 500, fontSize: 74, opacity: d, transform: up(d, 14) }}>github.com/tankibaj/keyloom</div>
      <div style={{ position: "absolute", top: 818, left: 0, right: 0, fontFamily: FONT_MONO, fontSize: 40, color: T.dim, opacity: d }}>brew install --cask tankibaj/tap/keyloom</div>
      <div style={{ position: "absolute", bottom: 22, left: 0, right: 0, fontSize: 16, color: "#8a8a8e", opacity: d }}>Mac and macOS are trademarks of Apple Inc., registered in the U.S. and other countries and regions.</div>
    </div>
  );
};
