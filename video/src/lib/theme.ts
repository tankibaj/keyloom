// Keyloom surfaces: stock macOS light and dark values (see plan section 7) plus the real TokenPill colours.
export type Theme = {
  win: string; side: string; list: string; line: string; txt: string; dim: string; field: string; rowSel: string; sel: string;
  blue: string; green: string; red: string; btn: string; pillBg: string; pillTx: string; term: string; termBox: string;
};
export const light: Theme = {
  win: "#ffffff", side: "#f3f3f6", list: "#fafafc", line: "#e5e5ea", txt: "#1d1d1f", dim: "#6e6e73", field: "#f2f2f5",
  rowSel: "rgba(60,60,67,0.10)", sel: "rgba(0,122,255,0.16)", blue: "#007aff", green: "#34c759", red: "#ff3b30", btn: "#ececf0",
  pillBg: "#E8F0FE", pillTx: "#0A58CA", term: "#fbfbfc", termBox: "#ffffff",
};
export const dark: Theme = {
  win: "#1e1e1e", side: "#252527", list: "#222224", line: "#38383a", txt: "#f5f5f7", dim: "#a1a1a6", field: "#2a2a2c",
  rowSel: "rgba(255,255,255,0.10)", sel: "rgba(10,132,255,0.30)", blue: "#0a84ff", green: "#30d158", red: "#ff453a", btn: "#3a3a3c",
  pillBg: "rgba(10,132,255,0.22)", pillTx: "#7CB8FF", term: "#161618", termBox: "#1e1e20",
};
export const ACCENT = "#007aff";
export const FONT_SANS = "Inter, -apple-system, system-ui, sans-serif";
export const FONT_MONO = '"JetBrains Mono", ui-monospace, Menlo, monospace';
export const INSTR: Record<string, string> = {
  plan: "Plan the change. List the steps, then wait.",
  implement: "Implement step one. Keep the diff small.",
  review: "Review the change below against the plan. List bugs first, then risks, then nits.",
  ship: "Ship it. Write the commit message and PR text.",
};
export const DIFF = ["- total = sum(prices)", "+ total = sum(p * q for p, q in lines)", "- tax = total * 0.19", "+ tax = round(total * rate, 2)"];
export const clamp01 = (x: number) => Math.max(0, Math.min(1, x));
