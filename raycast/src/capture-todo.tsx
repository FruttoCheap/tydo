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
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { useRef, useState } from "react";
import { ReviewItems } from "./import-document";
import { showTydoError, tydo } from "./lib/tydo";

export default function CaptureTodo() {
  const { push } = useNavigation();
  const [submitting, setSubmitting] = useState(false);
  const submittingRef = useRef(false);

  async function submit(values: { text: string }) {
    const text = values.text.trim();
    if (!text || submittingRef.current) return;
    submittingRef.current = true;
    setSubmitting(true);
    try {
      if (text.includes("\n")) {
        const directory = await mkdtemp(join(tmpdir(), "tydo-raycast-"));
        try {
          const path = join(directory, "capture.txt");
          await writeFile(path, text, "utf8");
          const items = await tydo.extractDocument(path);
          if (!items.length) {
            await showToast({
              style: Toast.Style.Failure,
              title: "No actionable items found",
            });
          } else {
            push(<ReviewItems items={items} />);
          }
        } finally {
          await rm(directory, { recursive: true, force: true });
        }
        return;
      }

      await tydo.add(text);
      await closeMainWindow();
      await showHUD("Todo captured. Tydo is processing it...");
      try {
        await tydo.process();
        await showHUD("Tydo finished processing");
      } catch (error) {
        await showHUD(
          `Todo saved, but processing failed: ${(error as Error).message}`,
        );
      }
    } catch (error) {
      await showTydoError("Could not capture todo", error);
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  }

  return (
    <Form
      enableDrafts
      isLoading={submitting}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Capture Todo"
            icon={Icon.Plus}
            onSubmit={submit}
          />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="text"
        title="Todo"
        placeholder="What needs doing?"
        autoFocus
      />
    </Form>
  );
}
