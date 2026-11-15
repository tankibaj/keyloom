import { Composition } from "remotion";
import { KeyloomFilm } from "./KeyloomFilm";
import { FPS, HEIGHT, WIDTH, TOTAL_FRAMES } from "./lib/anim";

export const Root = () => <Composition id="KeyloomFilm" component={KeyloomFilm} durationInFrames={TOTAL_FRAMES} fps={FPS} width={WIDTH} height={HEIGHT} />;
