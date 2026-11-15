import { AbsoluteFill, delayRender, continueRender, useCurrentFrame } from "remotion";
import { useEffect, useState } from "react";
import { fontsReady } from "./lib/fonts";
import { FPS, camStyle, camera, easeIn, easeInOut, easeOut, mix, ramp, spr, type Key } from "./lib/anim";
import { ACCENT, FONT_SANS, dark, light } from "./lib/theme";
import { Backdrop } from "./ui/Backdrop";
import { Counter } from "./ui/Counter";
import { Cursor } from "./ui/Cursor";
import { Sounds } from "./ui/Sounds";
import { wordCaption } from "./ui/WordCaption";
import { Problem, counterValue } from "./scenes/Problem";
import { ARG_PILL, CLIP_PILL, KW_RECT, Library, rowRect } from "./scenes/Library";
import { Proof } from "./scenes/Proof";
const T_CLICK = 21.45;
import { EndCard } from "./scenes/EndCard";

const PCAM: Key[] = [
  [9.0, 1.12, 960, 500], [11.4, 1, 960, 480], [12.2, 1.06, 960, 520], [12.9, 1.06, 960, 520], [14.5, 1, 960, 460],
  [15.3, 1.1, 1050, 480], [17.0, 1.1, 1050, 480], [17.6, 1.12, 1050, 480], [19.8, 1.12, 1050, 480], [20.6, 1.06, 960, 520],
  [22.5, 1.06, 960, 520], [22.9, 1, 960, 420],
];
const BCAM: Key[] = [
  [0, 1.1, 960, 455], [2.9, 1.13, 960, 460], [3.7, 1.22, 1000, 560], [5.0, 1.22, 1000, 560], [5.9, 1, 960, 540], [8.9, 1, 960, 540],
];

type R = { x: number; y: number; w: number; h: number };
const ringRect = (frame: number): { r: R; o: number } => {
  const keys: [number, R][] = [[11.6, rowRect(2)], [12.2, KW_RECT], [12.7, ARG_PILL], [13.1, CLIP_PILL]];
  const t = frame / FPS;
  let r = keys[0][1];
  for (let i = 0; i < keys.length - 1; i++) {
    const p = ramp(frame, keys[i][0], keys[i][0] + 0.4, easeInOut);
    if (t >= keys[i][0]) r = { x: mix(keys[i][1].x, keys[i + 1][1].x, p), y: mix(keys[i][1].y, keys[i + 1][1].y, p), w: mix(keys[i][1].w, keys[i + 1][1].w, p), h: mix(keys[i][1].h, keys[i + 1][1].h, p) };
  }
  const o = ramp(frame, 11.5, 11.7) * (1 - ramp(frame, 12.9, 13.2));
  return { r, o };
};

const Product = ({ frame, mode }: { frame: number; mode: "light" | "dark" }) => {
  const T = mode === "light" ? light : dark;
  const t = frame / FPS;
  const cam = camera(frame, PCAM);
  const intro = spr(frame, 9.2, 1.9, { damping: 20, stiffness: 55 });
  const libOut = ramp(frame, 13.0, 13.6, easeIn);
  const { r, o } = ringRect(frame);
  const libBack = ramp(frame, 20.3, 20.8, easeInOut);
  const proofOut = 1 - libBack;
  return (
    <div style={{ position: "absolute", inset: 0, ...camStyle(cam) }}>
      {(libOut < 1 || t >= 20.2) && (
        <div style={{ position: "absolute", inset: 0, opacity: t >= 20.2 ? libBack : 1 - libOut, transform: `scale(${mix(1, 0.94, libOut)})`, transformOrigin: "960px 440px" }}>
          <Library frame={frame} T={T} intro={intro} />
          {o > 0.01 && <div style={{ position: "absolute", left: r.x - 4, top: r.y - 4, width: r.w + 8, height: r.h + 8, borderRadius: 12, border: `3px solid ${T.blue}`, boxShadow: "0 0 0 6px rgba(0,122,255,.16)", opacity: o }} />}
        </div>
      )}
      {t >= 13.4 && t < 21 && (
        <div style={{ position: "absolute", inset: 0, opacity: proofOut, transform: `scale(${mix(1, 0.96, 1 - proofOut)})`, transformOrigin: "960px 460px" }}>
          <Proof frame={frame} T={T} enter={1} />
        </div>
      )}
    </div>
  );
};

export const KeyloomFilm = () => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const [handle] = useState(() => delayRender("fonts"));
  useEffect(() => {
    fontsReady.then(() => continueRender(handle)).catch(() => continueRender(handle));
  }, [handle]);

  const reveal = ramp(frame, 9.0, 10.1, (x) => 1 - Math.pow(1 - x, 4));
  const clip = `circle(${mix(0, 2400, reveal)}px at 1710px 130px)`;
  const pc = camera(frame, PCAM);
  const flipCx = 1720, flipCy = 90;
  const flip = ramp(frame, T_CLICK + 0.05, T_CLICK + 1.05, (x) => 1 - Math.pow(1 - x, 4));
  const flipClip = `circle(${mix(0, 2300, flip)}px at ${flipCx}px ${flipCy}px)`;
  const appOut = ramp(frame, 22.9, 23.4, easeIn);
  const endIn = ramp(frame, 23.4, 23.9);
  const scrim = Math.min(1, Math.max(0, (pc.s - 1.1) / 0.15)) * (t > 13.7 && t < 22.9 ? 1 : 0.0) + ((t > 11.7 && t < 13.2) || (t > 20.3 && t < 22.9) ? 1 : 0) + (t > 9.8 && t < 11.6 ? 0.9 : 0);
  const p = { color: light.txt, accent: ACCENT, bottom: 84 };
  const counterOp = t < 9.0 ? 1 : 1 - ramp(frame, 9.0, 9.4);
  const endCounter = ramp(frame, 23.5, 24.1, easeOut);
  const pulse = Math.max(0, Math.sin(Math.PI * Math.min(1, Math.max(0, (t - 5.4) / 0.6)))) + Math.max(0, Math.sin(Math.PI * Math.min(1, Math.max(0, (t - 2.9) / 0.4))));

  return (
    <AbsoluteFill style={{ fontFamily: FONT_SANS }}>
      <Sounds />
      <Backdrop frame={frame} mode="light" />
      {t < 10.2 && (
        <div style={{ position: "absolute", inset: 0, ...camStyle(camera(frame, BCAM)) }}>
          <Problem frame={frame} />
        </div>
      )}
      <Counter value={counterValue(t)} pulse={pulse} opacity={counterOp} />

      <div style={{ position: "absolute", inset: 0, clipPath: clip }}>
        <div style={{ position: "absolute", inset: 0, opacity: 1 - appOut, transform: `scale(${mix(1, 0.94, appOut)})` }}>
          <Product frame={frame} mode="light" />
          {flip > 0 && (
            <div style={{ position: "absolute", inset: 0, clipPath: flipClip }}>
              <Product frame={frame} mode="dark" />
            </div>
          )}
        </div>
      </div>
      {endIn > 0 && <div style={{ position: "absolute", inset: 0, opacity: endIn }}><EndCard frame={frame} /></div>}
      {endCounter > 0 && <Counter value={1} scale={0.6} opacity={endCounter} />}

      <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 400, opacity: Math.min(1, scrim), background: flip > 0.45 ? "linear-gradient(to top, rgba(30,30,30,.99) 0%, rgba(30,30,30,.97) 55%, rgba(30,30,30,0) 100%)" : "linear-gradient(to top, rgba(240,240,244,.99) 0%, rgba(240,240,244,.97) 55%, rgba(240,240,244,0) 100%)" }} />
      {wordCaption(frame, { ...p, text: "You've typed this prompt\n40 times today.", start: -0.15, end: 2.95, size: 104, accentWords: ["40"], gap: 0.13 })}
      {wordCaption(frame, { ...p, text: "Plan. Implement. Review. Ship.", start: 3.0, end: 5.1, size: 100, gap: 0.45 })}
      {wordCaption(frame, { ...p, text: "Same words. Every time.", start: 5.4, end: 7.95, size: 116, accentWords: ["Every", "time"], gap: 0.14 })}
      {wordCaption(frame, { ...p, text: "Type it once.", start: 8.0, end: 8.95, size: 120, accentWords: ["once"], gap: 0.12 })}
      {wordCaption(frame, { ...p, text: "Meet Keyloom.", start: 10.0, end: 11.5, size: 124 })}
      {wordCaption(frame, { ...p, text: "Write it once.", start: 11.7, end: 13.0, size: 96 })}
      {wordCaption(frame, { ...p, text: "Type the keyword.", start: 14.45, end: 16.65, size: 96 })}
      {wordCaption(frame, { ...p, text: "Your diff comes along.", start: 16.95, end: 20.4, size: 96, accentWords: ["diff"] })}
      {wordCaption(frame, { ...p, color: flip > 0.45 ? "#f5f5f7" : light.txt, text: "Light or dark.", start: 20.95, end: 22.9, size: 96 })}
    </AbsoluteFill>
  );
};
