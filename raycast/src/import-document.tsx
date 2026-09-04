import {
  Action,
  ActionPanel,
  closeMainWindow,
  Form,
  Icon,
  showHUD,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { basename, extname } from "node:path";
import { useRef, useState } from "react";
import { showTydoError, tydo } from "./lib/tydo";

const FILE_TYPES = [
  "pdf",
  "txt",
  "md",
  "markdown",
  "doc",
  "docx",
  "rtf",
  "rtfd",
  "html",
  "htm",
];

async function processAfterPersistence() {
  await showHUD("Todos saved. Tydo is processing them...");
  try {
    await tydo.process();
    await showHUD("Tydo finished processing");
  } catch (error) {
    await showHUD(
      `Todos saved, but processing failed: ${(error as Error).message}`,
    );
  }
}

export function ReviewItems({ items }: { items: string[] }) {
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);

  async function submit(values: Record<string, boolean>) {
    const selected = items.filter((_, index) => values[`item-${index}`]);
    if (!selected.length) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Select at least one todo",
      });
      return;
    }
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    try {
      await tydo.addMany(selected);
      await closeMainWindow();
      await processAfterPersistence();
    } catch (error) {
      await showTydoError("Could not save todos", error);
      savingRef.current = false;
      setSaving(false);
    }
  }

  return (
    <Form
      isLoading={saving}
      navigationTitle={`Review ${items.length} Todo${items.length === 1 ? "" : "s"}`}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Add Selected Todos"
            icon={Icon.Checkmark}
            onSubmit={submit}
          />
        </ActionPanel>
      }
    >
      <Form.Description text="Review the extracted actions. Checked items will be added to Tydo." />
      {items.map((item, index) => (
        <Form.Checkbox
          key={`${item}-${index}`}
          id={`item-${index}`}
          label={item}
          defaultValue
        />
      ))}
    </Form>
  );
}

export default function ImportDocument() {
  const { push } = useNavigation();
  const [extracting, setExtracting] = useState(false);

  async function submit(values: { files: string[] }) {
    if (!values.files.length) return;
    const unsupported = values.files.find(
      (file) => !FILE_TYPES.includes(extname(file).slice(1).toLowerCase()),
    );
    if (unsupported) {
      await showToast({
        style: Toast.Style.Failure,
        title: `Unsupported file: ${basename(unsupported)}`,
      });
      return;
    }
    setExtracting(true);
    const extracted: string[] = [];
    try {
      for (const file of values.files) {
        try {
          extracted.push(...(await tydo.extractDocument(file)));
        } catch (error) {
          throw new Error(`${basename(file)}: ${(error as Error).message}`);
        }
      }
      const seen = new Set<string>();
      const unique = extracted
        .map((item) => item.trim())
        .filter((item) => {
          const key = item.toLowerCase();
          if (!item || seen.has(key)) return false;
          seen.add(key);
          return true;
        });
      if (!unique.length) {
        await showToast({
          style: Toast.Style.Failure,
          title: "No actionable items found",
        });
      } else {
        push(<ReviewItems items={unique} />);
      }
    } catch (error) {
      await showTydoError("Document extraction failed", error);
    } finally {
      setExtracting(false);
    }
  }

  return (
    <Form
      isLoading={extracting}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Extract Todos"
            icon={Icon.Document}
            onSubmit={submit}
          />
        </ActionPanel>
      }
    >
      <Form.FilePicker
        id="files"
        title="Documents"
        info="Files are processed sequentially and subject to Tydo's document-size limit."
        allowMultipleSelection
        canChooseDirectories={false}
      />
    </Form>
  );
}
