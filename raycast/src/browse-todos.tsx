import {
  Action,
  ActionPanel,
  Alert,
  confirmAlert,
  Detail,
  Form,
  Icon,
  List,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { showTydoError, tydo } from "./lib/tydo";
import type { Snapshot, Todo } from "./lib/types";
import { MastermindView } from "./manage-tydo";

type Filter = "active" | "completed" | "all";

function date(value?: string) {
  return value ? new Date(value).toLocaleString() : "-";
}

function RenameTodo({
  todo,
  renamed,
}: {
  todo: Todo;
  renamed: () => Promise<void>;
}) {
  const { pop } = useNavigation();
  const [saving, setSaving] = useState(false);
  return (
    <Form
      isLoading={saving}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Rename Todo"
            onSubmit={async (values: { title: string }) => {
              const title = values.title.trim();
              if (!title) return;
              setSaving(true);
              try {
                await tydo.renameTodo(todo.id, title);
                await renamed();
                pop();
              } catch (error) {
                await showTydoError("Could not rename todo", error);
                setSaving(false);
              }
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="title"
        title="Title"
        defaultValue={todo.title}
        autoFocus
      />
    </Form>
  );
}

function TodoDetail({
  todo,
  actions,
}: {
  todo: Todo;
  actions: Parameters<typeof Detail>[0]["actions"];
}) {
  return (
    <Detail
      markdown={
        todo.body ? `# ${todo.title}\n\n${todo.body}` : `# ${todo.title}`
      }
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label
            title="Group"
            text={todo.groupName ?? "Processing"}
          />
          <Detail.Metadata.Label title="Status" text={todo.status} />
          <Detail.Metadata.Label title="Stage" text={todo.stage} />
          <Detail.Metadata.Label title="Created" text={date(todo.createdAt)} />
          <Detail.Metadata.Label
            title="Completed"
            text={date(todo.completedAt)}
          />
          {todo.rawText !== todo.title && (
            <Detail.Metadata.Label title="Original Text" text={todo.rawText} />
          )}
        </Detail.Metadata>
      }
      actions={actions}
    />
  );
}

export default function BrowseTodos() {
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [filter, setFilter] = useState<Filter>("active");
  const [busy, setBusy] = useState<string>();
  const mutating = useRef(false);

  async function refresh() {
    try {
      setSnapshot(await tydo.snapshot());
    } catch (error) {
      await showTydoError("Could not load todos", error);
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  async function mutate(
    key: string,
    operation: () => Promise<unknown>,
    success: string,
  ) {
    if (mutating.current) return false;
    mutating.current = true;
    setBusy(key);
    try {
      await operation();
      await refresh();
      await showToast({ style: Toast.Style.Success, title: success });
      return true;
    } catch (error) {
      await showTydoError(success, error);
      return false;
    } finally {
      mutating.current = false;
      setBusy(undefined);
    }
  }

  async function unassign(todo: Todo) {
    if (
      !(await mutate(
        `unassign-${todo.id}`,
        () => tydo.unassignTodo(todo.id),
        "Todo returned to processing",
      ))
    )
      return;
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Tydo is processing unassigned todos",
    });
    try {
      await tydo.process();
      toast.style = Toast.Style.Success;
      toast.title = "Tydo finished processing";
      await refresh();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Todo was unassigned, but processing failed";
      toast.message = (error as Error).message;
    }
  }

  function actions(todo: Todo, includeDetails = true) {
    const group = snapshot?.groups.find((item) => item.id === todo.groupID);
    const primaryKey = `${todo.status}-${todo.id}`;
    return (
      <ActionPanel>
        <Action
          title={todo.status === "active" ? "Complete Todo" : "Reopen Todo"}
          icon={
            todo.status === "active"
              ? Icon.CheckCircle
              : Icon.ArrowCounterClockwise
          }
          onAction={() =>
            mutate(
              primaryKey,
              () =>
                todo.status === "active"
                  ? tydo.completeTodo(todo.id)
                  : tydo.reopenTodo(todo.id),
              todo.status === "active" ? "Todo completed" : "Todo reopened",
            )
          }
        />
        {includeDetails && (
          <Action.Push
            title="Show Details"
            icon={Icon.Sidebar}
            target={<TodoDetail todo={todo} actions={actions(todo, false)} />}
          />
        )}
        <Action.Push
          title="Rename Todo"
          icon={Icon.Pencil}
          target={<RenameTodo todo={todo} renamed={refresh} />}
        />
        <ActionPanel.Submenu title="Move to Group" icon={Icon.Folder}>
          {snapshot?.groups.map((target) => (
            <Action
              key={target.id}
              title={target.name}
              onAction={() =>
                target.id !== todo.groupID &&
                mutate(
                  `move-${todo.id}`,
                  () => tydo.moveTodo(todo.id, target.id),
                  `Moved to ${target.name}`,
                )
              }
            />
          ))}
        </ActionPanel.Submenu>
        <Action
          title="Unassign and Reprocess"
          icon={Icon.ArrowCounterClockwise}
          onAction={() => todo.groupID && unassign(todo)}
        />
        {group && (
          <Action.Push
            title={`Plan ${group.name}`}
            icon={Icon.Stars}
            target={<MastermindView group={group} />}
          />
        )}
        <Action.Push
          title="Plan Everything"
          icon={Icon.Stars}
          target={<MastermindView />}
        />
        <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={refresh} />
        <Action
          title="Delete Todo"
          icon={Icon.Trash}
          style={Action.Style.Destructive}
          onAction={async () => {
            if (
              await confirmAlert({
                title: `Delete “${todo.title}”?`,
                message: "This permanently deletes the todo.",
                primaryAction: {
                  title: "Delete Todo",
                  style: Alert.ActionStyle.Destructive,
                },
              })
            ) {
              await mutate(
                `delete-${todo.id}`,
                () => tydo.deleteTodo(todo.id),
                "Todo deleted",
              );
            }
          }}
        />
      </ActionPanel>
    );
  }

  const todos = (snapshot?.todos ?? []).filter(
    (todo) => filter === "all" || todo.status === filter,
  );
  const sections = [
    ...((snapshot?.groups ?? []).map((group) => ({
      id: group.id,
      name: group.name,
    })) as Array<{ id?: string; name: string }>),
    { id: undefined, name: "Processing" },
  ];

  return (
    <List
      isLoading={!snapshot || !!busy}
      searchBarPlaceholder="Search title, text, body, or group"
      searchBarAccessory={
        <List.Dropdown
          tooltip="Todo Status"
          value={filter}
          onChange={(value) => setFilter(value as Filter)}
        >
          <List.Dropdown.Item title="Active" value="active" />
          <List.Dropdown.Item title="Completed" value="completed" />
          <List.Dropdown.Item title="All" value="all" />
        </List.Dropdown>
      }
    >
      {sections.map((section) => {
        const items = todos.filter((todo) => todo.groupID === section.id);
        return items.length ? (
          <List.Section
            key={section.id ?? "processing"}
            title={section.name}
            subtitle={String(items.length)}
          >
            {items.map((todo) => (
              <List.Item
                key={todo.id}
                title={todo.title}
                subtitle={todo.body}
                keywords={[
                  todo.rawText,
                  todo.body ?? "",
                  todo.groupName ?? "Processing",
                ]}
                icon={
                  todo.status === "completed"
                    ? Icon.CheckCircle
                    : todo.groupID
                      ? Icon.Circle
                      : Icon.Clock
                }
                accessories={[
                  { tag: todo.status },
                  { text: todo.groupName ?? "Processing" },
                  ...(todo.stage !== "grouped" ? [{ text: todo.stage }] : []),
                ]}
                actions={actions(todo)}
              />
            ))}
          </List.Section>
        ) : null;
      })}
    </List>
  );
}
