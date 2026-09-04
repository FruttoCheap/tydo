export type TodoStatus = "active" | "completed";
export type TodoStage = "raw" | "grammar" | "enriched" | "grouped";

export interface Todo {
  id: string;
  rawText: string;
  title: string;
  body?: string;
  status: TodoStatus;
  stage: TodoStage;
  createdAt: string;
  completedAt?: string;
  groupID?: string;
  groupName?: string;
}

export interface Group {
  id: string;
  name: string;
  isGeneral: boolean;
  createdByAI: boolean;
  createdAt: string;
  activeCount: number;
  completedCount: number;
}

export interface Clarification {
  id: string;
  todoID: string;
  todoTitle: string;
  optionGroupNames: string[];
  createdAt: string;
  wasPresented: boolean;
}

export interface Snapshot {
  todos: Todo[];
  groups: Group[];
  clarifications: Clarification[];
}

export interface MastermindProposal {
  id: string;
  title: string;
  body?: string;
  rationale: string;
  group: string;
}

export interface MastermindAnalysis {
  summary: string;
  proposals: MastermindProposal[];
}

export interface TydoConfig {
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
  reasoningBaseURL: string;
  reasoningChatModel: string;
  reasoningAPIKeyConfigured: boolean;
  retentionDays: number;
}

export interface ConfigUpdate {
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
  reasoningBaseURL: string;
  reasoningChatModel: string;
  reasoningAPIKey?: string | null;
  retentionDays: number;
}
