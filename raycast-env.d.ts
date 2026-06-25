/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Language - Whisper language code (pl, en, auto…). */
  "language": string,
  /** Microphone - ffmpeg avfoundation device, e.g. :default or :1 */
  "mic": string,
  /** Model path - Path to ggml whisper model. */
  "model": string,
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

