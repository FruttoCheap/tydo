import {
  Action,
  ActionPanel,
  Alert,
  confirmAlert,
  Form,
  Icon,
  List,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { showTydoError, tydo } from "./lib/tydo";
import type {
  Group,
  MastermindAnalysis,
  MastermindProposal,
  Snapshot,
  TydoConfig,
} from "./lib/types";

function failure(title: string, error: unknown) {
  return showTydoError(title, error);
}

function NameForm({
  title,
  initial = "",
  submit,
}: {
  title: string;
  initial?: string;
  submit: (name: string) => Promise<boolean>;
}) {
  const { pop } = useNavigation();
  const [saving, setSaving] = useState(false);

  return (
    <Form
      isLoading={saving}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title={title}
            onSubmit={async (values: { name: string }) => {
              const name = values.name.trim();
              if (!name) return;
              setSaving(true);
              try {
                if (await submit(name)) pop();
                else setSaving(false);
              } catch (error) {
                await failure(title, error);
                setSaving(false);
              }
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextField id="name" title="Name" defaultValue={initial} autoFocus />
    </Form>
  );
}

export function MastermindView({ group }: { group?: Group }) {
  const [analysis, setAnalysis] = useState<MastermindAnalysis>();
  const [busy, setBusy] = useState<string>();
  const running = useRef(false);

  async function analyze() {
    if (running.current) return;
    running.current = true;
    setBusy("analyze");
    try {
      setAnalysis(await tydo.analyze(group?.id));
    } catch (error) {
      await failure("Planning failed", error);
    } finally {
      running.current = false;
      setBusy(undefined);
    }
  }

  async function accept(proposal: MastermindProposal) {
    if (running.current) return;
    running.current = true;
    setBusy(proposal.id);
    try {
      await tydo.acceptProposal(proposal);
      setAnalysis((current) =>
        current
          ? {
              ...current,
              proposals: current.proposals.filter(
                (item) => item.id !== proposal.id,
              ),
            }
          : current,
      );
      await showToast({
        style: Toast.Style.Success,
        title: "Proposal added to Tydo",
      });
    } catch (error) {
      await failure("Could not accept proposal", error);
    } finally {
      running.current = false;
      setBusy(undefined);
    }
  }

  const analyzeAction = (
    <Action title="Analyze" icon={Icon.Stars} onAction={analyze} />
  );
  return (
    <List
      isLoading={busy === "analyze"}
      navigationTitle={group ? `Plan ${group.name}` : "Plan Everything"}
      isShowingDetail={!!analysis}
    >
      <List.Item
        title={
          analysis
            ? "Analysis Summary"
            : `Analyze ${group?.name ?? "all todos"}`
        }
        icon={Icon.Stars}
        detail={
          <List.Item.Detail
            markdown={
              analysis?.summary ??
              "Run Mastermind to generate a summary and proposed next actions."
            }
          />
        }
        actions={<ActionPanel>{analyzeAction}</ActionPanel>}
      />
      {analysis?.proposals.map((proposal) => (
        <List.Item
          key={proposal.id}
          title={proposal.title}
          subtitle={proposal.group}
          icon={Icon.LightBulb}
          detail={
            <List.Item.Detail
              markdown={`# ${proposal.title}\n\n${proposal.body ?? ""}\n\n## Rationale\n\n${proposal.rationale}\n\n**Target group:** ${proposal.group}`}
            />
          }
          actions={
            <ActionPanel>
              <Action
                title="Accept Proposal"
                icon={Icon.Checkmark}
                onAction={() => accept(proposal)}
              />
              <Action
                title="Dismiss Proposal"
                icon={Icon.XMarkCircle}
                onAction={() =>
                  !busy &&
                  setAnalysis((current) =>
                    current
                      ? {
                          ...current,
                          proposals: current.proposals.filter(
                            (item) => item.id !== proposal.id,
                          ),
                        }
                      : current,
                  )
                }
              />
              {analyzeAction}
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

function SettingsForm() {
  const { pop } = useNavigation();
  const [config, setConfig] = useState<TydoConfig>();
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    tydo
      .config()
      .then(setConfig)
      .catch((error) => failure("Could not load settings", error));
  }, []);

  if (!config) return <Form isLoading />;

  async function submit(values: Record<string, string | boolean>) {
    const retentionDays = Number(values.retentionDays);
    if (
      !Number.isInteger(retentionDays) ||
      retentionDays < 1 ||
      retentionDays > 365
    ) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Retention must be between 1 and 365 days",
      });
      return;
    }
    const key = String(values.apiKey).trim();
    if (key && values.clearKey) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Enter a replacement key or clear it, not both",
      });
      return;
    }
    setSaving(true);
    try {
      await tydo.updateConfig({
        baseURL: String(values.baseURL).trim(),
        chatModel: String(values.chatModel).trim(),
        embeddingModel: String(values.embeddingModel).trim(),
        reasoningBaseURL: String(values.reasoningBaseURL).trim(),
        reasoningChatModel: String(values.reasoningChatModel).trim(),
        ...(key
          ? { reasoningAPIKey: key }
          : values.clearKey
            ? { reasoningAPIKey: null }
            : {}),
        retentionDays,
      });
      await showToast({
        style: Toast.Style.Success,
        title: "Tydo settings saved",
      });
      pop();
    } catch (error) {
      await failure("Could not save settings", error);
      setSaving(false);
    }
  }

  return (
    <Form
      isLoading={!config || saving}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save Settings"
            icon={Icon.SaveDocument}
            onSubmit={submit}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="baseURL"
        title="Primary Base URL"
        defaultValue={config?.baseURL}
      />
      <Form.TextField
        id="chatModel"
        title="Primary Chat Model"
        defaultValue={config?.chatModel}
      />
      <Form.TextField
        id="embeddingModel"
        title="Embedding Model"
        defaultValue={config?.embeddingModel}
      />
      <Form.Separator />
      <Form.TextField
        id="reasoningBaseURL"
        title="Reasoning Base URL"
        defaultValue={config?.reasoningBaseURL}
      />
      <Form.TextField
        id="reasoningChatModel"
        title="Reasoning Chat Model"
        defaultValue={config?.reasoningChatModel}
      />
      <Form.PasswordField
        id="apiKey"
        title="Replacement API Key"
        placeholder={
          config?.reasoningAPIKeyConfigured
            ? "A key is configured"
            : "No custom key configured"
        }
      />
      <Form.Checkbox
        id="clearKey"
        label="Clear the configured API key"
        defaultValue={false}
      />
      <Form.Separator />
      <Form.TextField
        id="retentionDays"
        title="Completed Todo Retention (Days)"
        defaultValue={String(config?.retentionDays ?? 30)}
      />
    </Form>
  );
}

export default function ManageTydo() {
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [busy, setBusy] = useState<string>();
  const mutating = useRef(false);

  async function refresh() {
    try {
      setSnapshot(await tydo.snapshot());
    } catch (error) {
      await failure("Could not load Tydo", error);
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  async function mutate(
    key: string,
    operation: () => Promise<unknown>,
    title: string,
  ) {
    if (mutating.current) return false;
    mutating.current = true;
    setBusy(key);
    try {
      await operation();
      await refresh();
      await showToast({ style: Toast.Style.Success, title });
      return true;
    } catch (error) {
      await failure(title, error);
      return false;
    } finally {
      mutating.current = false;
      setBusy(undefined);
    }
  }

  const createGroup = (
    <Action.Push
      title="Create Group"
      icon={Icon.Plus}
      target={
        <NameForm
          title="Create Group"
          submit={(name) =>
            mutate(
              "create-group",
              () => tydo.createGroup(name),
              "Group created",
            )
          }
        />
      }
    />
  );

  return (
    <List
      isLoading={!snapshot || !!busy}
      searchBarPlaceholder="Search groups and questions"
    >
      <List.Section
        title="Pending Grouping Questions"
        subtitle={String(snapshot?.clarifications.length ?? 0)}
      >
        {snapshot?.clarifications.map((question) => (
          <List.Item
            key={question.id}
            title={question.todoTitle}
            subtitle="Choose a group"
            icon={Icon.QuestionMark}
            actions={
              <ActionPanel>
                {question.optionGroupNames.map((name) => (
                  <Action
                    key={name}
                    title={`Assign to ${name}`}
                    icon={Icon.ArrowRight}
                    onAction={() =>
                      mutate(
                        question.id,
                        () => tydo.resolveClarification(question.id, name),
                        `Assigned to ${name}`,
                      )
                    }
                  />
                ))}
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  onAction={refresh}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
      <List.Section title="Groups">
        {snapshot?.groups.map((group) => (
          <List.Item
            key={group.id}
            title={group.name}
            subtitle={group.createdByAI ? "Created by Tydo" : undefined}
            accessories={[
              { text: `${group.activeCount} active` },
              { text: `${group.completedCount} completed` },
            ]}
            actions={
              <ActionPanel>
                <Action.Push
                  title={`Plan ${group.name}`}
                  icon={Icon.Stars}
                  target={<MastermindView group={group} />}
                />
                {!group.isGeneral && (
                  <Action.Push
                    title="Rename Group"
                    icon={Icon.Pencil}
                    target={
                      <NameForm
                        title="Rename Group"
                        initial={group.name}
                        submit={(name) =>
                          mutate(
                            group.id,
                            () => tydo.renameGroup(group.id, name),
                            "Group renamed",
                          )
                        }
                      />
                    }
                  />
                )}
                {createGroup}
                {!group.isGeneral && (
                  <Action
                    title="Delete Group"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    onAction={async () => {
                      if (
                        await confirmAlert({
                          title: `Delete ${group.name}?`,
                          message:
                            "Todos in this group will be moved according to Tydo's group deletion rules.",
                          primaryAction: {
                            title: "Delete Group",
                            style: Alert.ActionStyle.Destructive,
                          },
                        })
                      ) {
                        await mutate(
                          group.id,
                          () => tydo.deleteGroup(group.id),
                          "Group deleted",
                        );
                      }
                    }}
                  />
                )}
                <Action
                  title="Refresh"
                  icon={Icon.ArrowClockwise}
                  onAction={refresh}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
      <List.Section title="Planning and Settings">
        <List.Item
          title="Plan Everything"
          icon={Icon.Stars}
          actions={
            <ActionPanel>
              <Action.Push
                title="Plan Everything"
                target={<MastermindView />}
              />
              {createGroup}
            </ActionPanel>
          }
        />
        <List.Item
          title="Provider and Retention Settings"
          icon={Icon.Gear}
          actions={
            <ActionPanel>
              <Action.Push title="Open Settings" target={<SettingsForm />} />
              {createGroup}
            </ActionPanel>
          }
        />
        <List.Item
          title="Run Maintenance"
          icon={Icon.Trash}
          actions={
            <ActionPanel>
              <Action
                title="Run Maintenance"
                icon={Icon.Trash}
                style={Action.Style.Destructive}
                onAction={async () => {
                  if (
                    await confirmAlert({
                      title: "Run Tydo maintenance?",
                      message:
                        "This permanently deletes completed todos beyond the configured retention period.",
                      primaryAction: {
                        title: "Run Maintenance",
                        style: Alert.ActionStyle.Destructive,
                      },
                    })
                  ) {
                    await mutate(
                      "maintenance",
                      () => tydo.maintenance(),
                      "Maintenance complete",
                    );
                  }
                }}
              />
              {createGroup}
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
