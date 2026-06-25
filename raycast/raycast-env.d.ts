/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Backend - Which transcription engine to use. */
  "backend": "local" | "parakeet" | "cloud" | "deepgram" | "elevenlabs",
  /** Language - Whisper language code (pl, en, auto…). */
  "language": string,
  /** Microphone - ffmpeg avfoundation device, e.g. :default or :1 */
  "mic": string,
  /** Custom vocabulary - Optional prompt to bias spelling of names/terms, e.g. 'Raycast, whisper.cpp, Jurczyk'. */
  "prompt": string,
  /** Model path (local) - Path to ggml whisper model. Used by the Local backend. */
  "model": string,
  /** Cloud API key - API key for the Cloud backend. Get a free one at console.groq.com. */
  "cloudKey": string,
  /** Cloud endpoint - OpenAI-compatible /audio/transcriptions URL. */
  "cloudUrl": string,
  /** Cloud model - Transcription model for the Cloud backend. */
  "cloudModel": string,
  /** Deepgram API key - API key for the Deepgram backend (console.deepgram.com). */
  "deepgramKey": string,
  /** ElevenLabs API key - API key for the ElevenLabs Scribe backend. */
  "elevenlabsKey": string,
  /** Auto-paste - When on, the transcript is pasted into the focused app. When off, it only lands on the clipboard. */
  "paste": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `toggle` command */
  export type Toggle = ExtensionPreferences & {}
  /** Preferences accessible in the `history` command */
  export type History = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `toggle` command */
  export type Toggle = {}
  /** Arguments passed to the `history` command */
  export type History = {}
}

