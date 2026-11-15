// Small stroke glyphs in the spirit of the product's symbol icons (own vector drawings).
const P = ({ children, c, s = 22 }: { children: React.ReactNode; c: string; s?: number }) => (
  <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{children}</svg>
);
export const GBubble = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M4 5h16v11H11l-4 3.5V16H4z" /><path d="M8 9h8M8 12h5" /></P>;
export const GClock = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><circle cx="12" cy="12" r="8.5" /><path d="M12 7v5l3 2" /></P>;
export const GPin = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M8 4h8M9.5 4v6L7 14h10l-2.5-4V4M12 14v6" /></P>;
export const GTag = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M3.5 12.5V5a1.5 1.5 0 0 1 1.5-1.5h7.5l8 8-9 9z" /><circle cx="8" cy="8" r="1.2" /></P>;
export const GTrash = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6" /></P>;
export const GSearch = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><circle cx="11" cy="11" r="6.5" /><path d="M16 16l4 4" /></P>;
export const GCompose = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M5 6h8M5 6v13h13v-8M18 4l2 2-8 8-3 1 1-3z" /></P>;
export const GList = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M9 6h11M9 12h11M9 18h11" /><path d="M4 6l1 1 2-2M4 12l1 1 2-2M4 18l1 1 2-2" /></P>;
export const GCode = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M8 7l-5 5 5 5M16 7l5 5-5 5M13.5 5l-3 14" /></P>;
export const GEye = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M2 12s3.5-6.5 10-6.5S22 12 22 12s-3.5 6.5-10 6.5S2 12 2 12z" /><circle cx="12" cy="12" r="3" /></P>;
export const GSend = ({ c, s }: { c: string; s?: number }) => <P c={c} s={s}><path d="M21 3L10 14M21 3l-7 18-4-7-7-4z" /></P>;
export const SNIP: Record<string, { c: string; tint: string; G: typeof GList }> = {
  Plan: { c: "#007aff", tint: "rgba(0,122,255,.14)", G: GList },
  Implement: { c: "#af52de", tint: "rgba(175,82,222,.14)", G: GCode },
  Review: { c: "#ff9500", tint: "rgba(255,149,0,.16)", G: GEye },
  Ship: { c: "#28b04a", tint: "rgba(52,199,89,.16)", G: GSend },
};
