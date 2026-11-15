import { Audio, Sequence, staticFile } from "remotion";
import { s } from "../lib/anim";

type Ev = [number, string, number];
const ks = (name: string, times: number[], vol: number): Ev[] => times.map((t) => [t, name, vol]);

// Soft, tactile UI sounds tied to the visible action. The film also works muted.
const EVENTS: Ev[] = [
  // problem: typing passes (counter climbing), counter lands on 40
  ...ks("tick", [0.05, 0.2, 0.42, 0.6, 0.8, 1.02, 1.2, 1.4, 1.57, 1.75, 1.9, 2.04, 2.2, 2.34, 2.47, 2.62, 2.75], 0.3),
  ...ks("key", [0.36, 0.95, 1.5, 1.97, 2.4, 2.8], 0.24),
  [2.9, "thud", 0.3],
  // plan / implement / review / ship words
  ...ks("tick", [3.05, 3.22, 3.5, 3.67, 3.95, 4.12, 4.4, 4.57], 0.3),
  ...ks("pop-hi", [3.0, 3.45, 3.9, 4.35], 0.14),
  // pull back, same words every time (counter pulse, slow clock)
  [5.2, "swish", 0.2], [5.45, "thud", 0.26],
  ...ks("tick", [6.0, 6.5, 7.0, 7.5], 0.16),
  // pivot: 40 -> 1
  [8.0, "whoosh-soft", 0.38], [8.85, "pop-hi", 0.45],
  [9.3, "whoosh", 0.28],
  // 3D planes
  [9.6, "pop", 0.3], [9.8, "pop-hi", 0.28], [10.0, "pop", 0.3], [10.2, "pop-hi", 0.28], [10.4, "pop", 0.3],
  // camera to editor, selection ring slides
  [11.6, "swish", 0.24], [12.2, "tick", 0.3], [12.7, "tick", 0.3], [13.1, "tick", 0.3],
  // copy the diff
  [13.7, "pop", 0.26], [14.05, "click", 0.5],
  // type ::review, then it expands
  ...ks("key", [14.8, 15.06, 15.32, 15.58, 15.84, 16.1, 16.36, 16.62], 0.42),
  [16.66, "zip", 0.5], [16.7, "pop", 0.36],
  // fill in
  ...ks("tick", [16.8, 17.1, 17.4, 17.9, 18.1, 18.3, 18.5], 0.3),
  [18.7, "ping", 0.4],
  // pull back, cursor to the toggle
  [19.8, "swish", 0.2], [20.3, "pop-hi", 0.2], [20.9, "tick", 0.22], [21.45, "click", 0.4],
  // light / dark
  [21.5, "whoosh-soft", 0.3], [22.9, "swish", 0.18],
  // end card
  [23.5, "pop-hi", 0.42], [24.1, "chime", 0.36],
];

export const Sounds = () => (
  <>
    {EVENTS.map(([t, name, vol], i) => (
      <Sequence key={i} from={s(t)} layout="none">
        <Audio src={staticFile(`sfx/${name}.wav`)} volume={vol} playbackRate={name === "key" || name === "tick" ? 0.92 + ((i * 7) % 11) * 0.02 : 1} />
      </Sequence>
    ))}
  </>
);
