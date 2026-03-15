import { defineConfig } from "tsup";

export default defineConfig([
  {
    entry: ["src/cli.ts"],
    format: ["esm"],
    target: "node20",
    clean: true,
    dts: true,
    sourcemap: true,
    banner: { js: "#!/usr/bin/env node" },
  },
  {
    entry: ["src/server.ts"],
    format: ["esm"],
    target: "node20",
    dts: true,
    sourcemap: true,
  },
  {
    entry: ["src/listener.ts"],
    format: ["esm"],
    target: "node20",
    dts: true,
    sourcemap: true,
    banner: { js: "#!/usr/bin/env node" },
  },
]);
