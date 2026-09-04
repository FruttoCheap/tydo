import {
  environment,
  LaunchType,
  showHUD,
  updateCommandMetadata,
} from "@raycast/api";
import { tydo } from "./lib/tydo";

export default async function CheckGroupingQuestions() {
  try {
    const snapshot = await tydo.snapshot();
    const unresolved = snapshot.clarifications.length;
    const fresh = snapshot.clarifications.filter(
      (question) => !question.wasPresented,
    );
    await updateCommandMetadata({
      subtitle: unresolved ? `${unresolved} pending` : "No pending questions",
    });

    if (environment.launchType === LaunchType.UserInitiated) {
      await showHUD(
        unresolved
          ? `${unresolved} grouping question${unresolved === 1 ? "" : "s"} pending`
          : "No grouping questions pending",
      );
      for (const question of fresh) {
        await tydo.markClarificationPresented(question.id);
      }
      return;
    }
    if (!fresh.length) return;

    await showHUD(
      `${fresh.length} new Tydo grouping question${fresh.length === 1 ? "" : "s"}`,
    );
    for (const question of fresh) {
      await tydo.markClarificationPresented(question.id);
    }
  } catch (error) {
    await showHUD(`Tydo question check failed: ${(error as Error).message}`);
  }
}
