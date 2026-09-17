defmodule Troupe.Client do
  @moduledoc """
  The only thing the TUI and HQ are allowed to talk to.

  Two implementations sit behind it: `Troupe.Client.Local`, which wraps the
  in-process session API, and `Troupe.Client.Remote`, which speaks the remote
  contract over the plane and worker connections. A session routes to one of
  them by id — a remote session's worker registers the route while it is
  attached, and everything else is local — so the two kinds can be on screen at
  the same time and the UI cannot tell them apart (Decision 73).

  Fleet-level calls (teams, profiles, listing and creating sessions) take an
  *origin* instead of a session id: `{:local, workspace}` or `{:remote,
  plane_url}`.

  `mix troupe.xref` fails the build if anything under `Troupe.UI` reaches past
  this module.
  """

  alias Troupe.Client.{Local, Remote}
  alias Troupe.{Config, Event}

  @type session_id :: String.t()
  @type origin :: {:local, String.t()} | {:remote, String.t()}
  @type decision :: :allow | :deny | :allow_session

  @typedoc """
  One session as a picker or HQ row shows it, whichever side it lives on.
  `state` is the remote vocabulary (`:active`, `:dormant`, `:read_only`,
  `:erased`); a local session is `:active` while it runs and `:dormant` once it
  is only on disk.
  """
  @type summary :: %{
          id: session_id(),
          title: String.t(),
          owner: String.t() | nil,
          team: String.t() | nil,
          profile: String.t() | nil,
          state: atom(),
          status: String.t() | nil,
          tokens: non_neg_integer() | nil,
          cost: number() | nil,
          updated_at: integer() | nil,
          origin: origin(),
          branches: list(),
          workspace: String.t() | nil
        }

  @typedoc "What a session allows right now, and why not when it does not."
  @type capability :: %{
          state: atom(),
          scopes: [String.t()],
          can_input?: boolean(),
          can_approve?: boolean(),
          reason: String.t() | nil,
          up?: boolean(),
          remote?: boolean()
        }

  ## Session-scoped

  @callback subscribe(session_id()) :: :ok
  @callback unsubscribe(session_id()) :: :ok
  @callback events(session_id()) :: [Event.t()]
  @callback commands(session_id()) :: [String.t()]
  @callback context(session_id()) :: {String.t(), Config.t()}
  @callback capability(session_id()) :: capability()
  @callback dispatch(session_id(), String.t(), String.t() | map()) ::
              {:ok, String.t()} | {:error, term()}
  @callback send_input(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback approve(session_id(), String.t(), decision()) :: :ok | {:error, term()}
  @callback answer(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback edit_todo(session_id(), String.t(), term()) :: :ok | {:error, term()}
  @callback switch_profile(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback cancel_branch(session_id(), String.t()) :: :ok | {:error, term()}
  @callback compact(session_id(), String.t()) :: :ok | {:error, term()}
  @callback dismiss(session_id(), String.t()) :: :ok | {:error, term()}
  @callback merge(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback discard(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback put_setting(session_id(), String.t(), term()) ::
              {:ok, Config.t(), String.t()} | {:error, term()}
  @callback watch(session_id(), boolean()) :: {:ok, atom()} | :ok | {:error, term()}
  @callback watch_status(session_id()) :: map()
  @callback memory(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback fs_list(session_id(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback fs_read(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback fs_upload(session_id(), String.t(), binary()) :: :ok | {:error, term()}
  @callback stop_session(session_id()) :: :ok | {:error, term()}
  @callback has_session?(session_id()) :: boolean()
  @callback idle?(session_id()) :: boolean()

  ## Fleet-scoped

  @callback teams(origin()) :: {:ok, [map()]} | {:error, term()}
  @callback profiles(origin(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  @callback sessions(origin(), map()) :: {:ok, [summary()]} | {:error, term()}
  @callback create_session(origin(), map()) :: {:ok, session_id()} | {:error, term()}
  @callback open_session(origin(), session_id(), :read | :activate, keyword()) ::
              {:ok, session_id()} | {:error, term()}
  @callback whoami(origin()) :: {:ok, map()} | {:error, term()}
  @callback fleet_status(origin()) :: map()
  @callback subscribe_fleet(origin()) :: :ok | {:error, term()}

  ## Routing

  @doc """
  Which implementation owns a session. A remote session's worker registers the
  route for as long as it is attached; everything else is local.
  """
  @spec impl(session_id()) :: module()
  def impl(session_id) do
    case Registry.lookup(Troupe.Registry, {:client, session_id}) do
      [{_pid, module}] when is_atom(module) -> module
      _ -> Local
    end
  end

  @doc "Registers the calling process as the owner of a session's route."
  @spec register(session_id(), module()) :: :ok
  def register(session_id, module) do
    case Registry.register(Troupe.Registry, {:client, session_id}, module) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @spec impl_for(origin()) :: module()
  def impl_for({:remote, _plane_url}), do: Remote
  def impl_for(_origin), do: Local

  @doc "Whether a session is a remote one."
  @spec remote?(session_id()) :: boolean()
  def remote?(session_id), do: impl(session_id) == Remote

  ## Session-scoped API

  @spec subscribe(session_id()) :: :ok
  def subscribe(sid), do: impl(sid).subscribe(sid)

  @spec unsubscribe(session_id()) :: :ok
  def unsubscribe(sid), do: impl(sid).unsubscribe(sid)

  @spec events(session_id()) :: [Event.t()]
  def events(sid), do: impl(sid).events(sid)

  @spec commands(session_id()) :: [String.t()]
  def commands(sid), do: impl(sid).commands(sid)

  @spec context(session_id()) :: {String.t(), Config.t()}
  def context(sid), do: impl(sid).context(sid)

  @spec capability(session_id()) :: capability()
  def capability(sid), do: impl(sid).capability(sid)

  @spec dispatch(session_id(), String.t(), String.t() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch(sid, name, args), do: impl(sid).dispatch(sid, name, args)

  @spec send_input(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_input(sid, path, text), do: impl(sid).send_input(sid, path, text)

  @spec approve(session_id(), String.t(), decision()) :: :ok | {:error, term()}
  def approve(sid, call_id, decision), do: impl(sid).approve(sid, call_id, decision)

  @spec answer(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def answer(sid, call_id, text), do: impl(sid).answer(sid, call_id, text)

  @spec edit_todo(session_id(), String.t(), term()) :: :ok | {:error, term()}
  def edit_todo(sid, path, change), do: impl(sid).edit_todo(sid, path, change)

  @spec switch_profile(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def switch_profile(sid, path, name), do: impl(sid).switch_profile(sid, path, name)

  @spec cancel_branch(session_id(), String.t()) :: :ok | {:error, term()}
  def cancel_branch(sid, path), do: impl(sid).cancel_branch(sid, path)

  @spec compact(session_id(), String.t()) :: :ok | {:error, term()}
  def compact(sid, path), do: impl(sid).compact(sid, path)

  @spec dismiss(session_id(), String.t()) :: :ok | {:error, term()}
  def dismiss(sid, path), do: impl(sid).dismiss(sid, path)

  @spec merge(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def merge(sid, path), do: impl(sid).merge(sid, path)

  @spec discard(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def discard(sid, path), do: impl(sid).discard(sid, path)

  @spec put_setting(session_id(), String.t(), term()) ::
          {:ok, Config.t(), String.t()} | {:error, term()}
  def put_setting(sid, key, value), do: impl(sid).put_setting(sid, key, value)

  @spec watch(session_id(), boolean()) :: {:ok, atom()} | :ok | {:error, term()}
  def watch(sid, enabled?), do: impl(sid).watch(sid, enabled?)

  @spec watch_status(session_id()) :: map()
  def watch_status(sid), do: impl(sid).watch_status(sid)

  @spec memory(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def memory(sid, command), do: impl(sid).memory(sid, command)

  @spec fs_list(session_id(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def fs_list(sid, path), do: impl(sid).fs_list(sid, path)

  @spec fs_read(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fs_read(sid, path), do: impl(sid).fs_read(sid, path)

  @spec fs_upload(session_id(), String.t(), binary()) :: :ok | {:error, term()}
  def fs_upload(sid, path, content), do: impl(sid).fs_upload(sid, path, content)

  @spec stop_session(session_id()) :: :ok | {:error, term()}
  def stop_session(sid), do: impl(sid).stop_session(sid)

  @spec has_session?(session_id()) :: boolean()
  def has_session?(sid), do: impl(sid).has_session?(sid)

  @doc "Whether a session has nothing on screen — the scratch session `troupe` opens."
  @spec idle?(session_id()) :: boolean()
  def idle?(sid), do: impl(sid).idle?(sid)

  ## Fleet API

  @spec teams(origin()) :: {:ok, [map()]} | {:error, term()}
  def teams(origin), do: impl_for(origin).teams(origin)

  @spec profiles(origin(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def profiles(origin, team \\ nil), do: impl_for(origin).profiles(origin, team)

  @spec sessions(origin(), map()) :: {:ok, [summary()]} | {:error, term()}
  def sessions(origin, filter \\ %{}), do: impl_for(origin).sessions(origin, filter)

  @spec create_session(origin(), map()) :: {:ok, session_id()} | {:error, term()}
  def create_session(origin, params), do: impl_for(origin).create_session(origin, params)

  @spec open_session(origin(), session_id(), :read | :activate, keyword()) ::
          {:ok, session_id()} | {:error, term()}
  def open_session(origin, sid, mode \\ :read, opts \\ []),
    do: impl_for(origin).open_session(origin, sid, mode, opts)

  @spec whoami(origin()) :: {:ok, map()} | {:error, term()}
  def whoami(origin), do: impl_for(origin).whoami(origin)

  @spec fleet_status(origin()) :: map()
  def fleet_status(origin), do: impl_for(origin).fleet_status(origin)

  @spec subscribe_fleet(origin()) :: :ok | {:error, term()}
  def subscribe_fleet(origin), do: impl_for(origin).subscribe_fleet(origin)

  ## Helpers the UI would otherwise reach into the harness for

  @doc "The worktrees `/worktree <Tab>` offers: checked out, and Troupe-managed."
  @spec worktrees(String.t()) :: {[map()], [String.t()]}
  def worktrees(workspace), do: Local.worktrees(workspace)

  @doc "The text a multiple-choice answer is sent as."
  @spec answer_text([String.t()]) :: String.t()
  def answer_text(labels), do: Local.answer_text(labels)

  @doc """
  Copies text to this machine's clipboard. The clipboard is the user's own
  machine whichever side the session lives on, so it is not routed through an
  implementation — but it still goes through the client, because the UI calls
  nothing else.
  """
  @spec copy(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def copy(text), do: Troupe.Clipboard.copy(text)

  @doc "The planes this machine is logged in to."
  @spec planes() :: [map()]
  def planes, do: Remote.planes()

  @doc "The origin of the plane `troupe --remote` opens without an argument."
  @spec default_plane() :: origin() | nil
  def default_plane, do: Remote.default_plane()

  @doc """
  Starts (or finds) the connection to a plane, so HQ and the sessions under it
  have something to talk to. `{:error, :logged_out}` when this machine has never
  logged in to that plane.
  """
  @spec connect_plane(String.t()) :: {:ok, origin()} | {:error, term()}
  def connect_plane(plane_url), do: Remote.connect(plane_url)
end
