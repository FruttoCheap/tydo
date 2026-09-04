import { Clipboard, getPreferenceValues, showToast, Toast } from "@raycast/api";
import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { spawn } from "node:child_process";
import type {
  Clarification,
  ConfigUpdate,
  Group,
  MastermindAnalysis,
  MastermindProposal,
  Snapshot,
  Todo,
  TydoConfig,
} from "./types";

const REQUIRED_CLI = "1.1.0";
const PROTOCOL = 1;
const INSTALL_COMMAND = "brew install FruttoCheap/tap/tydo";
const UPGRADE_COMMAND = "brew upgrade FruttoCheap/tap/tydo";
let executablePromise: Promise<string> | undefined;

interface SuccessEnvelope<T> {
  version: number;
  data: T;
}

interface ErrorEnvelope {
  version: number;
  code?:
    | "invalid_request"
    | "not_found"
    | "conflict"
    | "busy"
    | "timeout"
    | "internal";
  error: string;
}

interface RunOptions {
  input?: unknown;
  timeout?: number;
  signal?: AbortSignal;
}

export class TydoError extends Error {
  constructor(
    message: string,
    readonly code:
      | ErrorEnvelope["code"]
      | "missing_cli"
      | "incompatible_cli"
      | "malformed_response",
  ) {
    super(message);
  }
}

function versionAtLeast(actual: string, required: string) {
  const parse = (value: string) =>
    value.split(".").map((part) => Number.parseInt(part, 10));
  const left = parse(actual);
  const right = parse(required);
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    if ((left[index] ?? 0) !== (right[index] ?? 0))
      return (left[index] ?? 0) > (right[index] ?? 0);
  }
  return true;
}

function friendlyError(envelope: ErrorEnvelope) {
  switch (envelope.code) {
    case "invalid_request":
      return `Tydo rejected the request: ${envelope.error}`;
    case "not_found":
      return "That item no longer exists. Refresh and try again.";
    case "conflict":
      return `Tydo could not apply the change: ${envelope.error}`;
    case "busy":
      return "Tydo is busy. Try again in a moment.";
    case "timeout":
      return "Tydo's provider timed out. No mutation was retried.";
    case "internal":
      return `Tydo failed: ${envelope.error}`;
    default:
      return envelope.error || "Tydo failed without an explanation.";
  }
}

async function spawnJSON<T>(
  executable: string,
  args: string[],
  options: RunOptions = {},
): Promise<T> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      shell: false,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settledByClient: TydoError | undefined;
    let killTimer: NodeJS.Timeout | undefined;

    const terminate = (error: TydoError) => {
      if (settledByClient) return;
      settledByClient = error;
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), 1_000);
    };
    const timeout = setTimeout(
      () =>
        terminate(
          new TydoError("Tydo took too long and was stopped.", "timeout"),
        ),
      options.timeout ?? 15_000,
    );
    const abort = () =>
      terminate(new TydoError("Tydo was cancelled.", "timeout"));
    if (options.signal?.aborted) abort();
    else options.signal?.addEventListener("abort", abort, { once: true });

    child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk));
    child.on("error", (error: NodeJS.ErrnoException) => {
      clearTimeout(timeout);
      if (killTimer) clearTimeout(killTimer);
      options.signal?.removeEventListener("abort", abort);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      if (killTimer) clearTimeout(killTimer);
      options.signal?.removeEventListener("abort", abort);
      if (settledByClient) return reject(settledByClient);

      const source = code === 0 ? stdout : stderr;
      try {
        const envelope = JSON.parse(source) as
          SuccessEnvelope<T> | ErrorEnvelope;
        if (envelope.version !== PROTOCOL) {
          throw new TydoError(
            `Tydo protocol ${envelope.version} is unsupported; protocol ${PROTOCOL} is required.`,
            "incompatible_cli",
          );
        }
        if (code !== 0 || !("data" in envelope)) {
          const failure = envelope as ErrorEnvelope;
          throw new TydoError(
            friendlyError(failure),
            failure.code ?? "malformed_response",
          );
        }
        resolve(envelope.data);
      } catch (error) {
        reject(
          error instanceof TydoError
            ? error
            : new TydoError(
                `Tydo returned malformed JSON${stderr ? `: ${stderr.trim()}` : "."}`,
                "malformed_response",
              ),
        );
      }
    });

    if (options.input !== undefined)
      child.stdin.end(JSON.stringify(options.input));
    else child.stdin.end();
  });
}

async function discoverExecutable() {
  const override = getPreferenceValues<{ cliPath?: string }>().cliPath?.trim();
  const fixed = [
    override,
    "/opt/homebrew/bin/tydo",
    "/usr/local/bin/tydo",
    "/Applications/Tydo.app/Contents/Helpers/tydo",
  ].filter(Boolean) as string[];
  for (const candidate of fixed) {
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Continue to the next documented location.
    }
  }
  return "tydo";
}

async function executable() {
  if (!executablePromise) {
    executablePromise = (async () => {
      const candidate = await discoverExecutable();
      let version: { cli: string; protocolVersion: number };
      try {
        version = await spawnJSON(candidate, ["version"], { timeout: 5_000 });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") {
          throw new TydoError(
            `Tydo CLI was not found. Install it with: ${INSTALL_COMMAND}`,
            "missing_cli",
          );
        }
        throw error;
      }
      if (
        version.protocolVersion !== PROTOCOL ||
        !versionAtLeast(version.cli, REQUIRED_CLI)
      ) {
        throw new TydoError(
          `Tydo CLI ${REQUIRED_CLI}+ with protocol ${PROTOCOL} is required. Upgrade with: brew upgrade FruttoCheap/tap/tydo`,
          "incompatible_cli",
        );
      }
      return candidate;
    })();
  }
  return executablePromise;
}

export async function runTydo<T>(args: string[], options: RunOptions = {}) {
  return spawnJSON<T>(await executable(), args, options);
}

export function showTydoError(title: string, error: unknown) {
  const setupCommand =
    error instanceof TydoError
      ? error.code === "missing_cli"
        ? INSTALL_COMMAND
        : error.code === "incompatible_cli"
          ? UPGRADE_COMMAND
          : undefined
      : undefined;
  return showToast({
    style: Toast.Style.Failure,
    title,
    message: (error as Error).message,
    ...(setupCommand
      ? {
          primaryAction: {
            title: "Copy Homebrew Command",
            onAction: () => Clipboard.copy(setupCommand),
          },
        }
      : {}),
  });
}

export const tydo = {
  snapshot: (signal?: AbortSignal) =>
    runTydo<Snapshot>(["snapshot"], { signal }),
  add: (text: string) => runTydo<Todo>(["todo", "add", text]),
  addMany: (items: string[]) =>
    runTydo<Todo[]>(["todo", "add-many"], { input: items }),
  renameTodo: (id: string, title: string) =>
    runTydo<Todo>(["todo", "rename", id, title]),
  completeTodo: (id: string) => runTydo<Todo>(["todo", "complete", id]),
  reopenTodo: (id: string) => runTydo<Todo>(["todo", "reopen", id]),
  moveTodo: (todoID: string, groupID: string) =>
    runTydo<Todo>(["todo", "move", todoID, groupID]),
  unassignTodo: (id: string) => runTydo<Todo>(["todo", "unassign", id]),
  deleteTodo: (id: string) => runTydo(["todo", "delete", id, "--yes"]),
  createGroup: (name: string) => runTydo<Group>(["group", "create", name]),
  renameGroup: (id: string, name: string) =>
    runTydo<Group>(["group", "rename", id, name]),
  deleteGroup: (id: string) => runTydo(["group", "delete", id, "--yes"]),
  resolveClarification: (id: string, groupName: string) =>
    runTydo(["clarification", "resolve", id, groupName]),
  markClarificationPresented: (id: string) =>
    runTydo<Clarification>(["clarification", "mark-presented", id]),
  extractDocument: (path: string) =>
    runTydo<string[]>(["document", "extract", path], { timeout: 180_000 }),
  process: () => runTydo<Snapshot>(["process"], { timeout: 300_000 }),
  analyze: (groupID?: string) =>
    runTydo<MastermindAnalysis>(
      ["mastermind", "analyze", ...(groupID ? [groupID] : [])],
      { timeout: 300_000 },
    ),
  acceptProposal: (proposal: MastermindProposal) =>
    runTydo<Todo>(["mastermind", "accept"], {
      input: proposal,
      timeout: 180_000,
    }),
  config: () => runTydo<TydoConfig>(["config", "get"]),
  updateConfig: (update: ConfigUpdate) =>
    runTydo<TydoConfig>(["config", "update"], { input: update }),
  maintenance: () => runTydo<Snapshot>(["maintenance"], { timeout: 60_000 }),
};
