import {
  showHUD,
  getPreferenceValues,
  environment,
  LocalStorage,
} from "@raycast/api";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { homedir } from "node:os";
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";

const exec = promisify(execFile);

interface Prefs {
  backend: string;
  language: string;
  mic: string;
  prompt: string;
  model: string;
  cloudKey: string;
  cloudUrl: string;
  cloudModel: string;
  deepgramKey: string;
  elevenlabsKey: string;
  paste: boolean;
}

export interface HistoryItem {
  text: string;
  date: number;
}

export const HISTORY_KEY = "voicetype-history";
const HISTORY_LIMIT = 100;

const WORKDIR = join(environment.supportPath, "rec");
const PIDFILE = join(WORKDIR, "ffmpeg.pid");

/**
 * MVP: the bundled shell engine (voice-type.sh) does the heavy lifting so behaviour
 * stays identical to the Keyboard Maestro path. Roadmap: reimplement record/transcribe
 * natively in TS to drop the shell dependency before shipping to the Raycast Store.
 */
const ENGINE = join(environment.assetsPath, "voice-type.sh");

function expand(p: string): string {
  return p.startsWith("~") ? join(homedir(), p.slice(1)) : p;
}

function isRecording(): boolean {
  try {
    return existsSync(PIDFILE) && statSync(PIDFILE).size > 0;
  } catch {
    return false;
  }
}

async function saveToHistory(text: string): Promise<void> {
  const raw = await LocalStorage.getItem<string>(HISTORY_KEY);
  const items: HistoryItem[] = raw ? JSON.parse(raw) : [];
  items.unshift({ text, date: Date.now() });
  await LocalStorage.setItem(
    HISTORY_KEY,
    JSON.stringify(items.slice(0, HISTORY_LIMIT)),
  );
}

export default async function Command() {
  const prefs = getPreferenceValues<Prefs>();
  const stopping = isRecording();

  await showHUD(
    stopping ? "⏳ Transcribing…" : "🎙️ Recording… (run again to stop)",
  );

  const env = {
    ...process.env,
    PATH: `/opt/homebrew/bin:/usr/local/bin:${join(homedir(), ".local/bin")}:${process.env.PATH ?? ""}`,
    VOICETYPE_DIR: WORKDIR,
    VOICETYPE_BACKEND: prefs.backend || "local",
    VOICETYPE_LANG: prefs.language || "pl",
    VOICETYPE_MIC: prefs.mic || ":default",
    VOICETYPE_PROMPT: prefs.prompt || "",
    VOICETYPE_MODEL: expand(prefs.model),
    VOICETYPE_CLOUD_KEY: prefs.cloudKey || "",
    VOICETYPE_CLOUD_URL: prefs.cloudUrl || "",
    VOICETYPE_CLOUD_MODEL: prefs.cloudModel || "",
    VOICETYPE_DEEPGRAM_KEY: prefs.deepgramKey || "",
    VOICETYPE_ELEVENLABS_KEY: prefs.elevenlabsKey || "",
    VOICETYPE_PASTE: prefs.paste ? "1" : "0",
  };

  try {
    const { stdout } = await exec("/bin/bash", [ENGINE], {
      env,
      timeout: 120_000,
    });
    const text = stdout.trim();
    if (stopping && text) {
      await saveToHistory(text);
      await showHUD(`✅ ${text.length > 60 ? text.slice(0, 60) + "…" : text}`);
    }
  } catch (err) {
    await showHUD(
      `❌ ${err instanceof Error ? err.message : "VoiceType failed"}`,
    );
  }
}
