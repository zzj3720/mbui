// micro.ts in Hermes (bench/hermes-host gives __bench and __native): what the app's bundle puts in first, then the cases.
import "../../src/hosts/hermes-globals.ts";
import { runMicro } from "./micro.ts";

void runMicro();
