import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import type { HitlConfig } from "./types.js";

const DEFAULT_CONFIG_PATH = path.join(os.homedir(), ".claude-hitl.json");

export function resolveEnvValue(value: string): string {
  if (!value.startsWith("env:")) return value;
  const envKey = value.slice(4);
  const envVal = process.env[envKey];
  if (envVal === undefined) {
    throw new Error(
      `Environment variable ${envKey} is not set (referenced as "env:${envKey}" in config)`
    );
  }
  return envVal;
}

export function loadConfig(configPath?: string): HitlConfig | null {
  const filePath = configPath ?? process.env.CLAUDE_HITL_CONFIG ?? DEFAULT_CONFIG_PATH;
  if (!fs.existsSync(filePath)) return null;

  const raw = fs.readFileSync(filePath, "utf-8");
  const parsed = JSON.parse(raw);
  if (!parsed.adapter || typeof parsed.adapter !== "string") {
    throw new Error("Invalid config: missing required 'adapter' field");
  }
  return parsed as HitlConfig;
}

export function saveConfig(config: HitlConfig, configPath?: string): void {
  const filePath = configPath ?? DEFAULT_CONFIG_PATH;
  fs.writeFileSync(filePath, JSON.stringify(config, null, 2) + "\n", "utf-8");
}
