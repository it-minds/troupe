defmodule Troupe.Gateway.HarnessCase do
  @moduledoc """
  Several clients, distinct principals, one session — the shape stage 4 is about.

  Stage 4's done items are all statements about *more than one* attached client, so the
  fixture has to give each client an identity of its own. A Unix socket cannot: its
  permissions are the authentication and every connection is the same person. So these
  run against a `:remote` endpoint whose authenticator maps a token to a subject, which
  is what a worker pod does with a minted session token and what makes "every input
  carries the right author" a question with an answer.
  """

  use ExUnit.CaseTemplate

  alias Troupe.Gateway.{Daemon, Listener}
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Client, Endpoint, Error}

  using do
    quote do
      import Troupe.Gateway.HarnessCase

      alias Troupe.Protocol.{Client, Event}
    end
  end

  setup context do
    base = Path.join(System.tmp_dir!(), "troupe-harness-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    # `@tag limits: [outbound_bound: ...]` for the tests that are about what happens when a
    # client stops keeping up. Everything else gets the production bounds, because a
    # fixture that quietly ran under tiny ones would be proving something else.
    limits = Map.get(context, :limits, [])

    start_supervised!(
      {Daemon,
       [
         endpoint: Endpoint.remote(0, &__MODULE__.authenticate/1),
         idle_shutdown_ms: :timer.hours(1)
       ] ++ limits}
    )

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, state_dir: state_dir, port: Listener.port()}
  end

  @doc """
  The test authenticator: the token *is* the subject.

  Deliberately trivial. What matters here is that two connections can be two different
  people; how a real worker decides that is `Troupe.Worker.Auth`'s business and is
  tested there.
  """
  @spec authenticate(map()) :: {:ok, map(), [atom()]} | {:error, Error.t()}
  def authenticate(params) do
    case get_in(params, ["auth", "token"]) do
      nil ->
        {:error, Error.new(:unauthenticated)}

      token ->
        {subject, scopes} = parse_token(token)
        {:ok, %{"subject" => subject, "display_name" => subject, "kind" => "user"}, scopes}
    end
  end

  # `ada@example.test` gets everything; `bob@example.test#observe` gets only observe.
  defp parse_token(token) do
    case String.split(token, "#") do
      [subject, "observe"] -> {subject, [:observe]}
      [subject] -> {subject, [:observe, :control, :admin]}
    end
  end

  @doc "Attach a client as one particular person."
  @spec attach(map(), String.t(), keyword()) :: pid()
  def attach(context, subject, opts \\ []) do
    {:ok, client} =
      Client.connect(
        [
          address: {127, 0, 0, 1},
          port: context.port,
          token: subject,
          client_info: %{"name" => "harness", "version" => "1"}
        ] ++ opts
      )

    # `on_exit` only works from the test process, and clients are deliberately also
    # attached from tasks and collectors. Those are torn down with the test anyway.
    try do
      ExUnit.Callbacks.on_exit(fn -> Client.close(client) end)
    rescue
      ArgumentError -> :ok
    end

    client
  end

  @doc "A session with a scripted model behind it."
  @spec start_session(map(), keyword()) :: map()
  def start_session(context, opts \\ []) do
    fake =
      ExUnit.Callbacks.start_supervised!(
        {Fake, Keyword.take(opts, [:steps, :routes, :default, :delay_ms])},
        id: {Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        [
          workspace: context.workspace,
          fake: fake,
          config_overrides:
            [provider: "fake", model: "fake", state_dir: context.state_dir] ++
              Keyword.get(opts, :config, auto_approve: true)
        ] ++ Keyword.take(opts, [:definitions])
      )

    ExUnit.Callbacks.on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  @doc """
  Collect events for one topic until `done?` says stop, or the deadline passes.

  Returns them in arrival order, which is the thing under test: two clients that
  collected the same durable events in a different order would be the failure.
  """
  @spec collect(String.t(), (Troupe.Protocol.Event.t() -> boolean()), timeout()) ::
          [Troupe.Protocol.Event.t()]
  def collect(topic, done?, timeout \\ 30_000) do
    do_collect(topic, done?, System.monotonic_time(:millisecond) + timeout, [])
  end

  defp do_collect(topic, done?, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:troupe_event, ^topic, _session_id, event} ->
          acc = [event | acc]
          if done?.(event), do: Enum.reverse(acc), else: do_collect(topic, done?, deadline, acc)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  @doc "Wait for a condition, polling, with a readable failure when it never holds."
  @spec eventually((-> any()), timeout()) :: any()
  def eventually(fun, timeout \\ 5_000) do
    poll(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          ExUnit.Assertions.flunk("condition never held")
        else
          Process.sleep(20)
          poll(fun, deadline)
        end

      truthy ->
        truthy
    end
  end
end
