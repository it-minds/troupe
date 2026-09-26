defmodule Troupe.Plane.Repo.Migrations.SessionPendingQuestions do
  @moduledoc """
  How many questions a session has open, beside how many approvals.

  A session waiting on a question — the agent's `ask_user`, or the budget's or the failure
  guard's — is waiting on a person as surely as one waiting on an approval, and a queue
  listed from the index has to see it. The worker reports it with the other lifecycle
  facts, and it is rebuildable from the log the same way.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:pending_questions, :integer, null: false, default: 0)
    end
  end
end
