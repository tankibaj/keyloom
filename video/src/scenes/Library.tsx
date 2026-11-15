import type { CSSProperties, ReactNode } from "react";
import { FPS, easeInOut, mix, ramp, spr } from "../lib/anim";
import { FONT_MONO, FONT_SANS, type Theme } from "../lib/theme";
import { Body } from "../ui/Body";
import { SNIP, GEye, GBubble, GClock, GCompose, GPin, GSearch, GTag, GTrash } from "../ui/Glyphs";
import { Lights, shadowStack } from "../ui/Win";

export const LX = 160, LY = 50, LW = 1600, LH = 780;
const SBW = 260, LIW = 340, TB = 52;
export const ROWS = [["Plan", "::plan"], ["Implement", "::implement"], ["Review", "::review"], ["Ship", "::ship"]];
export const rowRect = (i: number) => ({ x: LX + SBW + 10, y: LY + 72 + i * 76, w: LIW - 20, h: 68 });
// Stage-space rectangles used by the selection ring (checked against rendered frames).
export const KW_RECT = { x: LX + 600 + 130, y: LY + 160, w: 600, h: 44 };
export const ARG_PILL = { x: 887, y: 483, w: 560, h: 34 };
export const CLIP_PILL = { x: 805, y: 571, w: 139, h: 32 };

type PlaneProps = { sepI: number; z: number; T: Theme; x: number; y: number; w: number; h: number; bg: string; r: [number, number, number, number]; appear: number; children?: ReactNode; style?: CSSProperties };
const Plane = ({ sepI, z, T, x, y, w, h, bg, r, appear, children, style }: PlaneProps) => {
  const dark = T.win === "#1e1e1e";
  const ri = mix(0, 16, sepI);
  const rad = r.map((v) => (v < 0 ? ri : v)).map((v) => `${v}px`).join(" ");
  const sh = sepI < 0.02 ? "none" : `0 ${30 * sepI}px ${60 * sepI}px rgba(0,0,0,${(dark ? 0.55 : 0.2) * sepI}), 0 ${6 * sepI}px ${14 * sepI}px rgba(0,0,0,${(dark ? 0.4 : 0.1) * sepI})`;
  return (
    <div style={{ position: "absolute", left: x, top: y, width: w, height: h, background: bg, borderRadius: rad, boxShadow: sh, opacity: Math.min(1, appear * 1.6), transform: `translateZ(${z * sepI}px) scale(${mix(0.94, 1, appear)})`, ...style }}>{children}</div>
  );
};

const SideItem = ({ T, y, icon, label, count, active }: { T: Theme; y: number; icon: ReactNode; label: string; count?: string; active?: boolean }) => (
  <div style={{ position: "absolute", left: 14, right: 14, top: y, height: 44, borderRadius: 10, background: active ? T.rowSel : "transparent", display: "flex", alignItems: "center", gap: 12, padding: "0 12px", fontFamily: FONT_SANS, fontWeight: 500, fontSize: 20, color: T.txt }}>
    {icon}<span style={{ flex: 1 }}>{label}</span>{count && <span style={{ color: T.dim, fontSize: 17 }}>{count}</span>}
  </div>
);
const Label = ({ T, y, children }: { T: Theme; y: number; children: ReactNode }) => (
  <div style={{ position: "absolute", left: 28, top: y, fontFamily: FONT_SANS, fontWeight: 600, fontSize: 15, color: T.dim }}>{children}</div>
);
const Field = ({ T, x, y, w, h, children }: { T: Theme; x: number; y: number; w: number; h: number; children?: ReactNode }) => (
  <div style={{ position: "absolute", left: x, top: y, width: w, height: h, background: T.field, borderRadius: 10, boxSizing: "border-box", padding: "0 16px", display: "flex", alignItems: "center", fontFamily: FONT_SANS, fontSize: 21, color: T.txt }}>{children}</div>
);
const Btn = ({ T, children, disabled, w }: { T: Theme; children: ReactNode; disabled?: boolean; w?: number }) => (
  <div style={{ height: 34, minWidth: w, padding: "0 16px", boxSizing: "border-box", borderRadius: 17, background: T.btn, color: disabled ? T.dim : T.txt, opacity: disabled ? 0.7 : 1, display: "grid", placeItems: "center", fontFamily: FONT_SANS, fontWeight: 600, fontSize: 17 }}>{children}</div>
);

/** The Keyloom library window as five 3D planes (sidebar, list, editor, toolbar, preview) that start exploded on Z and settle flat. */
export const Library = ({ frame, T, intro }: { frame: number; T: Theme; intro: number }) => {
  const t = frame / FPS;
  const sep = (i: number) => 1 - ramp(frame, 9.45 + 0.1 * i, 10.45 + 0.1 * i, easeInOut);
  const ap = (i: number) => spr(frame, 9.1 + 0.12 * i, 0.7);
  const rotX = mix(16, 0, intro), rotY = mix(-26, 0, intro), rotZ = mix(2, 0, intro);
  const dark = T.win === "#1e1e1e";
  const selT = ramp(frame, 11.5, 11.9);
  return (
    <div style={{ position: "absolute", inset: 0, perspective: 2600, perspectiveOrigin: "50% 52%" }}>
      <div style={{ position: "absolute", left: LX, top: LY, width: LW, height: LH, transformStyle: "preserve-3d", transform: `rotateX(${rotX}deg) rotateY(${rotY}deg) rotateZ(${rotZ}deg) scale(${mix(0.88, 1, intro)})` }}>
        <div style={{ position: "absolute", inset: 0, borderRadius: 16, background: T.win, boxShadow: shadowStack(mix(1.3, 1, intro), dark), opacity: Math.min(1, ap(0) * 2) }} />
        {/* sidebar */}
        <Plane sepI={sep(0)} z={70} T={T} x={0} y={0} w={SBW} h={LH} bg={T.side} r={[16, -1, -1, 16]} appear={ap(0)}>
          <div style={{ position: "absolute", left: 22, top: 20 }}><Lights /></div>
          <div style={{ position: "absolute", right: 14, top: 12, width: 34, height: 28, borderRadius: 8, border: `1.5px solid ${T.dim}`, opacity: 0.6 }} />
          <Label T={T} y={76}>Library</Label>
          <SideItem T={T} y={102} active icon={<GBubble c="#007aff" />} label="All Snippets" count="4" />
          <SideItem T={T} y={148} icon={<GClock c="#ff9500" />} label="Recently Used" />
          <SideItem T={T} y={194} icon={<GPin c="#ff3b30" />} label="Pinned" />
          <Label T={T} y={268}>Tags</Label>
          <SideItem T={T} y={294} icon={<span style={{ width: 22, textAlign: "center", fontWeight: 700, fontSize: 24, color: "#f5b800" }}>#</span>} label="agents" count="4" />
          <SideItem T={T} y={340} icon={<span style={{ width: 22, textAlign: "center", fontWeight: 700, fontSize: 24, color: "#ff3b30" }}>#</span>} label="code" count="2" />
          <SideItem T={T} y={386} icon={<span style={{ width: 22, textAlign: "center", fontWeight: 700, fontSize: 24, color: "#14b8a6" }}>#</span>} label="docs" count="1" />
          <SideItem T={T} y={460} icon={<GTrash c="#8e8e93" />} label="Recently Deleted" />
        </Plane>
        {/* list */}
        <Plane sepI={sep(1)} z={130} T={T} x={SBW} y={0} w={LIW} h={LH} bg={T.list} r={[-1, -1, -1, -1]} appear={ap(1)} style={{ borderLeft: `1px solid ${T.line}`, borderRight: `1px solid ${T.line}` }}>
          {ROWS.map(([name, kw], i) => {
            const p = spr(frame, 9.6 + 0.1 * i, 0.8);
            const sel = i === 2;
            return (
              <div key={name} style={{ position: "absolute", left: 10, top: 72 + i * 76, width: LIW - 20, height: 68, borderRadius: 12, background: sel ? T.rowSel : "transparent", display: "flex", alignItems: "center", gap: 14, padding: "0 14px", boxSizing: "border-box", opacity: Math.min(1, p * 1.6), transform: `translateX(${(1 - p) * 40}px)` }}>
                <div style={{ width: 44, height: 44, borderRadius: 11, background: SNIP[name].tint, display: "grid", placeItems: "center" }}>{(() => { const G = SNIP[name].G; return <G c={SNIP[name].c} s={24} />; })()}</div>
                <div>
                  <div style={{ fontFamily: FONT_SANS, fontWeight: 600, fontSize: 21, color: T.txt }}>{name}</div>
                  <div style={{ fontFamily: FONT_MONO, fontSize: 15, color: T.dim, marginTop: 2 }}>{kw}</div>
                </div>
              </div>
            );
          })}
        </Plane>
        {/* editor */}
        <Plane sepI={sep(2)} z={190} T={T} x={SBW + LIW} y={0} w={LW - SBW - LIW} h={LH} bg={T.win} r={[-1, -1, 16, -1]} appear={ap(2)}>
          <div style={{ position: "absolute", left: 28, top: 76, width: 64, height: 64, borderRadius: 14, background: SNIP.Review.tint, display: "grid", placeItems: "center" }}><GEye c={SNIP.Review.c} s={32} /></div>
          <Field T={T} x={108} y={76} w={864} h={64}><span style={{ fontWeight: 600, fontSize: 28 }}>Review</span></Field>
          <div style={{ position: "absolute", left: 28, top: 172, fontFamily: FONT_SANS, fontSize: 18, color: T.dim }}>Keyword</div>
          <Field T={T} x={130} y={160} w={600} h={44}>
            <span style={{ fontFamily: FONT_MONO, fontSize: 21, flex: 1 }}>::review</span>
            <span style={{ display: "flex", alignItems: "center", gap: 7, fontFamily: FONT_SANS, fontWeight: 600, fontSize: 15, color: T.green, background: "rgba(52,199,89,.16)", borderRadius: 12, padding: "3px 11px" }}><span style={{ width: 8, height: 8, borderRadius: 4, background: T.green }} />Free</span>
          </Field>
          <div style={{ position: "absolute", left: 746, top: 166, display: "flex", alignItems: "center", gap: 12, whiteSpace: "nowrap", fontFamily: FONT_SANS, fontSize: 17, color: T.txt }}>
            <div style={{ order: 2, flexShrink: 0, width: 50, height: 30, borderRadius: 15, background: T.blue, position: "relative" }}><div style={{ position: "absolute", right: 3, top: 3, width: 24, height: 24, borderRadius: 12, background: "#fff", boxShadow: "0 1px 3px rgba(0,0,0,.3)" }} /></div>Expand automatically
          </div>
          <div style={{ position: "absolute", left: 28, top: 226, fontFamily: FONT_SANS, fontSize: 18, color: T.dim }}>Tags</div>
          <Field T={T} x={130} y={214} w={600} h={44}>agents</Field>
          <div style={{ position: "absolute", left: 28, top: 270, display: "flex", gap: 8 }}>
            {["B", "I", "U"].map((k) => <div key={k} style={{ width: 52, height: 36, borderRadius: 9, background: T.btn, display: "grid", placeItems: "center", fontFamily: FONT_SANS, fontWeight: k === "B" ? 700 : 500, fontStyle: k === "I" ? "italic" : "normal", textDecoration: k === "U" ? "underline" : "none", fontSize: 19, color: T.txt }}>{k}</div>)}
          </div>
          <div style={{ position: "absolute", right: 28, top: 270, height: 36, padding: "0 16px", borderRadius: 9, background: T.btn, display: "flex", alignItems: "center", fontFamily: FONT_SANS, fontWeight: 500, fontSize: 18, color: T.txt }}>{"{ } Insert Placeholder  ⌄"}</div>
          <div style={{ position: "absolute", left: 28, right: 28, top: 322, height: 250, border: `1.5px solid ${T.line}`, borderRadius: 10, boxSizing: "border-box", padding: "14px 16px" }}>
            <Body T={T} size={24} lh={44} />
          </div>
          <div style={{ position: "absolute", left: 38, top: 596, fontFamily: FONT_SANS, fontWeight: 600, fontSize: 15, color: T.dim }}>Preview and Try Expansion</div>
        </Plane>
        {/* preview */}
        <Plane sepI={sep(3)} z={340} T={T} x={SBW + LIW + 28} y={624} w={LW - SBW - LIW - 56} h={128} bg={T.field} r={[12, 12, 12, 12]} appear={ap(3)}>
          <div style={{ padding: "12px 16px", fontFamily: FONT_SANS, fontSize: 19, lineHeight: "26px", color: T.txt }}>
            Review the change below against the plan.<br />List bugs first, then risks, then nits.<br />Scope: the whole diff<br /><span style={{ color: T.dim }}>‹clipboard›</span>
          </div>
        </Plane>
        {/* toolbar */}
        <Plane sepI={sep(4)} z={260} T={T} x={SBW} y={0} w={LW - SBW} h={TB} bg={T.win} r={[-1, 16, -1, -1]} appear={ap(4)} style={{ borderBottom: `1px solid ${T.line}`, display: "flex", alignItems: "center", padding: "0 20px", gap: 12 }}>
          <div style={{ fontFamily: FONT_SANS, fontWeight: 700, fontSize: 22, color: T.txt, flex: 1 }}>Keyloom</div>
          <div style={{ width: 38, height: 34, borderRadius: 17, background: T.btn, display: "grid", placeItems: "center" }}><GCompose c={T.txt} s={20} /></div>
          <Btn T={T}>Cancel</Btn><Btn T={T} disabled>Save</Btn>
          <div style={{ width: 280, height: 34, borderRadius: 17, background: T.btn, display: "flex", alignItems: "center", gap: 8, padding: "0 12px", fontFamily: FONT_SANS, fontSize: 17, color: T.dim }}><GSearch c={T.dim} s={18} />Search snippets</div>
        </Plane>
      </div>
      {selT >= 0 && null}
    </div>
  );
};
