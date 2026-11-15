import { FPS, easeIn, easeInOut, easeOut, mix, ramp, spr } from "../lib/anim";
import { FONT_SANS, INSTR, light as T } from "../lib/theme";
import { CARET, TermWindow } from "../ui/Term";

// [start, end, key]: one typing pass; the prompt is sent 0.06s after it ends, then the field clears.
export const PASSES: [number, number, string][] = [
  [-1.5, -1.0, "review"], [-0.95, -0.5, "review"],
  [-0.45, 0.35, "review"], [0.42, 0.95, "review"], [1.02, 1.5, "review"], [1.57, 1.97, "review"], [2.04, 2.4, "review"], [2.47, 2.8, "review"],
  [3.0, 3.4, "plan"], [3.45, 3.85, "implement"], [3.9, 4.3, "review"], [4.35, 4.75, "ship"],
];
const SEND = 0.06;

const typed = (t: number) => {
  for (let k = 0; k < PASSES.length; k++) {
    const [a, b, key] = PASSES[k];
    const next = PASSES[k + 1]?.[0] ?? 99;
    if (t >= a && t < next) {
      const full = INSTR[key];
      if (t < b) return { text: full.slice(0, Math.floor(full.length * ((t - a) / (b - a)))), typing: true, key };
      if (k === PASSES.length - 1 || t < b + SEND) return { text: full, typing: false, key };
      return { text: "", typing: false, key };
    }
  }
  return { text: "", typing: false, key: "review" };
};
const sentCount = (frame: number) => PASSES.reduce((n, [, b]) => n + ramp(frame, b + SEND, b + SEND + 0.15, (x) => x), 0);

const KEYS = ["plan", "implement", "review", "ship"];
const SLOTS = [[110, 230], [1010, 230], [110, 545], [1010, 545]];
const GW = 800, GH = 295, MW = 1000, MH = 570, MX = 460, MY = 70;

export const Problem = ({ frame }: { frame: number }) => {
  const t = frame / FPS;
  const { text, typing } = typed(t);
  const caretOn = typing || Math.floor(t * 2.4) % 2 === 0;
  const sentF = sentCount(frame);
  const msgs = PASSES.map(([, , k]) => INSTR[k]);
  const collapse = ramp(frame, 8.0, 8.9, easeIn);
  const lineIn = spr(frame, 8.5, 0.6);

  return (
    <>
      {KEYS.map((key, i) => {
        // i = 0..2 are the rear windows, 3 is the front (main) window
        const rear = 3 - i;
        const sx = i === 3 ? MX : MX - 62 * rear, sy = i === 3 ? MY : MY - 44 * rear;
        const appear = i === 3 ? 1 : spr(frame, 3.0 + 0.12 * (2 - i), 0.8);
        const g = ramp(frame, 5.2 + 0.06 * i, 5.95 + 0.06 * i, easeInOut);
        const x0 = mix(sx, SLOTS[i][0], g), y0 = mix(sy, SLOTS[i][1], g);
        const w = mix(MW, GW, g), h = mix(MH, GH, g);
        const float = ramp(frame, 5.9, 6.2) * Math.sin(t * 1.4 + i * 1.7) * 5;
        const cx = x0 + w / 2, cy = y0 + h / 2;
        const q = collapse;
        const ncx = mix(cx, 960, q), ncy = mix(cy, 520, q);
        const sc = mix(1, 0.45, q);
        const op = Math.min(appear * 1.5, 1) * (1 - ramp(frame, 8.45, 8.95, easeIn));
        const front = i === 3;
        const own = front ? text : INSTR[key];
        const input = <>{own}{front && g < 0.01 ? CARET(caretOn, T) : null}</>;
        const rearOff = i === 3 ? 0 : (1 - appear) * 70;
        const showMsgs = front && g < 0.5 ? msgs : [];
        return (
          <TermWindow key={key} T={T} x={ncx - w / 2} y={ncy - h / 2} w={w} h={h} inputH={front && g < 0.5 ? 130 : 120}
            msgs={showMsgs} sentF={sentF} input={front && g > 0.5 ? INSTR.ship : input} dy={float + rearOff} scale={sc} opacity={op}
            badge={g > 0.6 ? "×10" : undefined} title="web-app" />
        );
      })}
      {lineIn > 0.01 && (
        <div style={{ position: "absolute", left: 460, top: 460, width: 1000, height: 100, borderRadius: 22, background: "#fff", boxShadow: "0 30px 70px rgba(0,0,0,.18), 0 6px 16px rgba(0,0,0,.08)", display: "flex", alignItems: "center", justifyContent: "center", fontFamily: FONT_SANS, fontWeight: 600, fontSize: 36, color: "#1d1d1f", opacity: Math.min(1, lineIn * 1.5) * (1 - ramp(frame, 9.5, 9.9)), transform: `scale(${mix(0.8, 1, easeOut(lineIn))})` }}>
          Review the change below against the plan.
        </div>
      )}
    </>
  );
};

export const counterValue = (t: number) => {
  if (t < 2.9) return 1 + 39 * Math.pow(Math.max(0, t) / 2.9, 1.7);
  if (t < 8.0) return 40;
  if (t < 8.8) return mix(40, 1, easeInOut((t - 8.0) / 0.8));
  return 1;
};
