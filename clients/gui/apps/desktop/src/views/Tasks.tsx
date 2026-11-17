// The backstage's running order, and the person's hand in it (`todo.edit`): a task still
// open is marked complete or cancelled, and one is added at the foot, as the terminal
// client's /todo does. The harness takes an edit between turns and during one, applies it
// to the list and tells the model, so the pane is editable whenever the session may be
// changed by this person; its text is the agent's, and the protocol has no edit of it.

import { useState } from "react";
import type { JSX } from "react";
import type { TodoItem } from "@troupe/client";

export type TodoEdit = (action: "add" | "cancel" | "complete", params: { id?: string; content?: string }) => Promise<void>;

const OPEN = new Set(["pending", "in_progress"]);

export function Tasks({
  todo,
  onEdit,
}: {
  todo: TodoItem[];
  /** Absent where the person may only read the session. */
  onEdit?: TodoEdit | undefined;
}): JSX.Element {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState("");
  const edit = async (action: "add" | "cancel" | "complete", params: { id?: string; content?: string }): Promise<boolean> => {
    if (!onEdit) return false;
    setBusy(true);
    setError(null);
    try {
      await onEdit(action, params);
      return true;
    } catch (e) {
      setError(`It was not changed. ${e instanceof Error ? e.message : String(e)}.`);
      return false;
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {todo.length === 0 ? (
        <p className="note">No task list yet.</p>
      ) : (
        <ul className="tasks">
          {todo.map((t) => (
            <li key={t.id} className={t.status}>
              <span className="task-text">{t.content}</span>
              {onEdit && OPEN.has(t.status) && (
                <span className="task-acts">
                  <button type="button" className="link" disabled={busy} aria-label={`Complete: ${t.content}`} onClick={() => void edit("complete", { id: t.id })}>
                    Complete
                  </button>
                  <button type="button" className="link" disabled={busy} aria-label={`Cancel: ${t.content}`} onClick={() => void edit("cancel", { id: t.id })}>
                    Cancel
                  </button>
                </span>
              )}
            </li>
          ))}
        </ul>
      )}
      {onEdit && (
        <form
          className="task-add"
          onSubmit={(e) => {
            e.preventDefault();
            const content = adding.trim();
            if (!content) return;
            void edit("add", { content }).then((done) => done && setAdding(""));
          }}
        >
          <input
            aria-label="Add a task"
            placeholder="Add a task"
            value={adding}
            disabled={busy}
            onChange={(e) => setAdding(e.target.value)}
          />
        </form>
      )}
      {error && (
        <p className="note error" role="alert">
          {error}
        </p>
      )}
    </>
  );
}
