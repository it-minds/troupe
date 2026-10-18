defmodule Troupe.Plane.GitHub.Webhook do
  @moduledoc """
  The App's webhook: `POST /webhook/github`, where GitHub sends the events of the
  repositories the App is installed on.

  ## The door

  A delivery is taken only signed: `X-Hub-Signature-256` is the HMAC-SHA256 of the body as
  it arrived, under the App's webhook secret, which transit holds
  (`GitHub.WebhookSecret`), compared in constant time. One with no signature, or a wrong
  one, is refused before anything about it is read, and the refusal is logged with the
  delivery's id and event and never its body. A plane with no secret refuses every
  delivery and says why.

  A delivery is done once. Its id (`X-GitHub-Delivery`) is a row, written before any work
  starts, so GitHub sending it again, as it does after a timeout or when somebody presses
  Redeliver, is answered and does nothing more.

  It answers at once and works afterwards: GitHub gives a delivery ten seconds and records
  a slower answer as failed, and starting a session can take longer than that. What the
  work did is kept on the delivery's row (`outcome`).

  ## What a delivery does

  - `issues` (`labeled`) and `issue_comment` (`created`): fire every enabled trigger on
    the repository whose label or command it is (`GitHub.Issue`). Each is a run of its
    own, keyed by the delivery and the trigger, so a redelivery fires none twice.
  - `pull_request_review` (`submitted`): resume the session whose draft pull request it
    reviews (`GitHub.Review`); and `issue_comment` (`created`) on a pull request's
    conversation, the same with the comment.
  - `ping`, which GitHub sends when the webhook is set up: nothing.
  - Anything else: nothing. A delivery about a repository of no installation the plane
    lists does nothing either.

  Nothing in an issue, a comment or a review is an instruction to the plane: what it acts
  on is the event's name, its action, a label's name, a command's exact first line, and
  who GitHub says sent it.
  """

  import Ecto.Query, only: [from: 2]

  alias Troupe.Plane.{GitHub, Repo, Triggers}
  alias Troupe.Plane.GitHub.{Delivery, Issue, Review, WebhookSecret}
  alias Troupe.Protocol.Error

  require Logger

  @tasks Troupe.Plane.GitHub.Deliveries

  # How long a delivery's id is remembered. GitHub redelivers on request for some days;
  # a month is past any of them.
  @keep_days 30

  @doc "The name of the task supervisor deliveries are worked under."
  @spec tasks() :: atom()
  def tasks, do: @tasks

  @doc """
  Take a delivery: `body` exactly as it arrived, and its headers by lower-case name.

  `{:ok, :accepted}` once it is checked, recorded and its work started; `{:ok,
  :duplicate}` for a delivery already taken; `{:error, reason}` for a refusal, with
  `:unsigned` and `:mismatch` for a signature that is missing or wrong, `:no_secret` for a
  plane that has none, and `:malformed` for a signed body that is not a delivery.
  """
  @spec take(binary(), %{String.t() => String.t()}) ::
          {:ok, :accepted | :duplicate} | {:error, atom() | term()}
  def take(body, headers) when is_binary(body) do
    event = headers["x-github-event"]
    delivery = headers["x-github-delivery"]

    with :ok <- signed(body, headers["x-hub-signature-256"], event, delivery),
         {:ok, payload, event, delivery} <- read(body, event, delivery) do
      delivery |> record(event, payload["action"]) |> begin(event, delivery, payload)
    end
  end

  defp begin(:new, event, delivery, payload) do
    start(fn -> work(event, delivery, payload) end)
    {:ok, :accepted}
  end

  defp begin(:seen, event, delivery, _payload) do
    Logger.info("troupe plane: GitHub delivery #{delivery} (#{event}) again; already taken")
    {:ok, :duplicate}
  end

  # Before anything else is read: an unsigned or badly signed request learns nothing, and
  # its body is in no log line.
  defp signed(body, signature, event, delivery) do
    case check(body, signature) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "troupe plane: refused a GitHub delivery #{loggable(delivery)} (#{loggable(event)}): " <>
            refusal(reason)
        )

        {:error, reason}
    end
  end

  # A plane that was never given a secret has nothing to check against, and says so
  # without asking transit.
  defp check(body, signature) do
    case GitHub.app() do
      %{webhook_secret_version: version} when is_integer(version) ->
        WebhookSecret.check(body, signature)

      _none ->
        {:error, :no_secret}
    end
  end

  defp refusal(:unsigned), do: "no X-Hub-Signature-256, or not sha256= and 64 hex digits"
  defp refusal(:mismatch), do: "its signature is not the webhook secret's"
  defp refusal(:no_secret), do: "this plane has no webhook secret; set one with admin.github.put"
  defp refusal(other), do: "the signature could not be checked: #{GitHub.explain(other)}"

  # Headers are the sender's to write, so a log line takes only the characters an id or
  # an event name has.
  defp loggable(nil), do: "(none)"

  defp loggable(value) do
    value |> String.replace(~r/[^A-Za-z0-9._-]/, "") |> String.slice(0, 64)
  end

  defp read(body, event, delivery) do
    with true <- is_binary(event) and Regex.match?(~r/\A[a-z_]{1,64}\z/, event),
         true <- is_binary(delivery) and Regex.match?(~r/\A[A-Za-z0-9-]{1,64}\z/, delivery),
         {:ok, %{} = payload} <- Jason.decode(body) do
      {:ok, payload, event, delivery}
    else
      _ ->
        Logger.warning(
          "troupe plane: a signed GitHub delivery #{loggable(delivery)} " <>
            "(#{loggable(event)}) was not one: no event, no id, or a body that is not an object"
        )

        {:error, :malformed}
    end
  end

  # Inserted or not by the primary key alone, so two replicas given the same delivery at
  # once agree on which of them does it.
  defp record(delivery, event, action) do
    now = DateTime.utc_now()
    row = %{id: delivery, event: event, action: action && to_string(action), received_at: now}

    case Repo.insert_all(Delivery, [row], on_conflict: :nothing, conflict_target: :id) do
      {1, _} ->
        forget_before(DateTime.add(now, -@keep_days * 86_400, :second))
        :new

      {0, _} ->
        :seen
    end
  end

  defp forget_before(cutoff) do
    Repo.delete_all(from(d in Delivery, where: d.received_at < ^cutoff))
  end

  # Supervised where the plane runs one; a test that starts no application gets a task of
  # its own, which is the same work without the supervisor.
  defp start(fun) do
    case Process.whereis(@tasks) do
      nil -> Task.start(fun)
      _supervisor -> Task.Supervisor.start_child(@tasks, fun)
    end
  end

  # -- the work -----------------------------------------------------------------------

  @doc """
  What a delivery does, after it was taken: fire, resume or nothing, kept on its row.
  Public for a test that hands it a delivery without the door.
  """
  @spec work(String.t(), String.t(), map()) :: map()
  def work(event, delivery, payload) do
    outcome =
      try do
        act(event, delivery, payload)
      rescue
        exception ->
          Logger.error(
            "troupe plane: GitHub delivery #{delivery} (#{event}) failed: " <>
              Exception.message(exception)
          )

          %{"failed" => "the plane could not act on it"}
      end

    Repo.update_all(from(d in Delivery, where: d.id == ^delivery), set: [outcome: outcome])
    outcome
  end

  defp act("ping", _delivery, _payload), do: %{"ping" => true}

  # A comment on a pull request's conversation comes as an issue's comment too; it is about
  # a run's draft, never a command that starts one.
  defp act("issue_comment", delivery, %{"issue" => %{"pull_request" => %{}}} = payload),
    do: Review.resume_comment(delivery, payload)

  defp act(event, delivery, payload) when event in ["issues", "issue_comment"] do
    if installed?(payload),
      do: fire(event, delivery, payload),
      else: %{"ignored" => "a repository of no installation of this plane's App"}
  end

  defp act("pull_request_review", delivery, payload), do: Review.resume(delivery, payload)

  defp act(event, _delivery, payload),
    do: %{"ignored" => "#{event}#{action(payload)} is not an event this plane acts on"}

  defp action(%{"action" => action}) when is_binary(action), do: ".#{action}"
  defp action(_payload), do: ""

  defp installed?(payload) do
    GitHub.installed?(
      get_in(payload, ["repository", "owner", "login"]),
      get_in(payload, ["installation", "id"])
    )
  end

  defp fire(event, delivery, payload) do
    full_name = get_in(payload, ["repository", "full_name"])

    matched =
      if is_binary(full_name),
        do:
          full_name
          |> Triggers.on_repository()
          |> Enum.filter(&Issue.matches?(&1.source, event, payload)),
        else: []

    case matched do
      [] ->
        %{
          "ignored" =>
            "no trigger on #{full_name || "the repository"} starts for #{event}#{action(payload)}"
        }

      triggers ->
        %{"fired" => Enum.map(triggers, &fire_one(&1, event, delivery, payload))}
    end
  end

  defp fire_one(trigger, event, delivery, payload) do
    run_event = Issue.event(event, delivery, payload, trigger.source)
    key = "github:#{delivery}:#{trigger.id}"
    by = "github:#{get_in(payload, ["sender", "login"]) || "unknown"}"

    case Triggers.fire(trigger, "webhook", key, run_event, by) do
      {:ok, fired} ->
        Logger.info(
          "troupe plane: GitHub delivery #{delivery} fired trigger #{trigger.name}: " <>
            "run #{fired.run.id}, #{Triggers.state_of(fired.run, fired.session)}"
        )

        %{"trigger" => trigger.name, "run" => fired.run.id, "session_id" => fired.run.session_id}
        |> then(&if(fired.run.reason, do: Map.put(&1, "skipped", fired.run.reason), else: &1))

      {:error, %Error{} = error} ->
        Logger.warning(
          "troupe plane: GitHub delivery #{delivery} could not fire trigger #{trigger.name}: " <>
            "#{error.message} #{inspect(error.data)}"
        )

        %{"trigger" => trigger.name, "refused" => error.message}
    end
  end
end
