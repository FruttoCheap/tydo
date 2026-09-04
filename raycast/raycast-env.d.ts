/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Tydo CLI Path - Optional absolute path to a development build of tydo */
  "cliPath"?: string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `capture-todo` command */
  export type CaptureTodo = ExtensionPreferences & {}
  /** Preferences accessible in the `browse-todos` command */
  export type BrowseTodos = ExtensionPreferences & {}
  /** Preferences accessible in the `import-document` command */
  export type ImportDocument = ExtensionPreferences & {}
  /** Preferences accessible in the `manage-tydo` command */
  export type ManageTydo = ExtensionPreferences & {}
  /** Preferences accessible in the `check-grouping-questions` command */
  export type CheckGroupingQuestions = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `capture-todo` command */
  export type CaptureTodo = {}
  /** Arguments passed to the `browse-todos` command */
  export type BrowseTodos = {}
  /** Arguments passed to the `import-document` command */
  export type ImportDocument = {}
  /** Arguments passed to the `manage-tydo` command */
  export type ManageTydo = {}
  /** Arguments passed to the `check-grouping-questions` command */
  export type CheckGroupingQuestions = {}
}

