import type { ReactNode } from "react";
import { FONT_MONO, FONT_SANS, type Theme } from "../lib/theme";

/** Placeholder pill with the real TokenPill colours (light #E8F0FE / #0A58CA, dark rgba(10,132,255,.22) / #7CB8FF). */
export const Pill = ({ T, children, size }: { T: Theme; children: ReactNode; size: number }) => (
  <span style={{ display: "inline-block", background: T.pillBg, color: T.pillTx, fontFamily: FONT_MONO, fontSize: size * 0.78, padding: `0 ${size * 0.34}px`, borderRadius: size * 0.3, lineHeight: `${size * 1.3}px`, verticalAlign: "middle", whiteSpace: "nowrap" }}>{children}</span>
);

export const ARG = '{argument name="scope" default="the whole diff"}';

/** The ::review template body, one row per line. */
export const bodyRows = (T: Theme, size: number): ReactNode[] => [
  "Review the change below against the plan.",
  "List bugs first, then risks, then nits.",
  <span key="s">Scope: <Pill T={T} size={size}>{ARG}</Pill></span>,
  "",
  <Pill key="c" T={T} size={size}>{"{clipboard}"}</Pill>,
];

export const Body = ({ T, size, lh }: { T: Theme; size: number; lh: number }) => (
  <div style={{ fontFamily: FONT_SANS, fontSize: size, color: T.txt }}>
    {bodyRows(T, size).map((r, i) => <div key={i} style={{ height: lh, lineHeight: `${lh}px`, whiteSpace: "nowrap" }}>{r}</div>)}
  </div>
);
