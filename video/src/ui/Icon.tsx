// Keyloom's own app icon (Icon/AppIcon.icon: teal fill, front vertical bars, back horizontal bars at 55%).
export const KeyloomIcon = ({ size }: { size: number }) => (
  <svg width={size} height={size} viewBox="0 0 1024 1024" style={{ display: "block", filter: "drop-shadow(0 18px 30px rgba(13,100,104,.35))" }}>
    <defs>
      <linearGradient id="kg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#25b6b9" /><stop offset="1" stopColor="#0b8286" /></linearGradient>
    </defs>
    <rect width="1024" height="1024" rx="230" fill="url(#kg)" />
    <g fill="#fff" opacity="0.55"><rect x="232" y="292" width="560" height="110" rx="55" /><rect x="232" y="457" width="560" height="110" rx="55" /><rect x="232" y="622" width="560" height="110" rx="55" /></g>
    <g fill="#fff"><rect x="292" y="232" width="110" height="560" rx="55" /><rect x="457" y="232" width="110" height="560" rx="55" /><rect x="622" y="232" width="110" height="560" rx="55" /></g>
  </svg>
);
