defmodule Troupe.Gateway.Policy do
  @moduledoc """
  The plane's word on this machine kept up to date while its person is signed in (#657):
  the version policy and the organisation's document, which an administrator may change at
  any time.

  The daemon dials the plane and nothing dials the daemon, so it asks: every thirty seconds
  while it holds a token (`poll_ms`), the plane's `initialize` again (`Plane.handshake/0`),
  which judges this daemon's version against the policy as it now stands and names a
  `policy.revision`, a digest of what the plane's two signed answers would say. Where the
  revision moved, or there was none yet, the two answers are fetched and checked as at a
  link:

    * the organisation's document (`me.client_defaults`), kept as the plane signed it
      (`keep_organisation/2`); where its defaults or limits changed, every client hears
      `config.changed` (scope `org`) and every session running here is resolved again,
      taking the change at its next turn with a line saying so
      (`Troupe.Session.Organisation`);
    * the version policy (`me.client_versions`), checked against the pinned key; where it
      changed, every client hears `config.changed` (scope `versions`), so the desktop app
      asks again what to update to.

  A poll costs the plane one `initialize`, and OpenBao nothing: the revision is not signed,
  and the answers that are signed are fetched only when it moves. A forged revision makes
  the daemon ask, or not ask; what it acts on is still only what the pinned key signed.
  Nothing here fails loudly: a plane that does not answer is asked again at the next poll.
  While every client attached is in Local only (`Troupe.Gateway.LocalOnly`), a poll asks
  nothing.
  """

  use GenServer

  alias Troupe.Config.Org
  alias Troupe.Config.Settings
  alias Troupe.Gateway.{Connections, LocalOnly, Plane}
  alias Troupe.PlaneKeys
  alias Troupe.Session.Organisation

  require Logger

  @poll_ms :timer.seconds(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Keep a plane's `me.client_defaults` answer as this machine's copy of the organisation's
  document, as the plane signed it: checked against the key pinned for the plane, and saved
  with the signature, which is checked again whenever the copy is read. One the pin refuses
  leaves the copy before it, and says why; a plane that signs nothing has its document kept
  as it always was, and that said in the log. Where the defaults or limits changed, every
  client hears which keys, and every session running here takes them at its next turn.
  """
  @spec keep_organisation(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def keep_organisation(plane_url, document) do
    before = organisation()

    with {:ok, body, signed?} <- PlaneKeys.check(plane_url, document, "client_defaults"),
         :ok <- unsigned_line(plane_url, signed?),
         {:ok, kept} <- Org.save(plane_url, body, Org.cache_path(), signature(signed?, document)) do
      now = organisation()

      keys =
        Enum.uniq(
          Settings.changed(before["defaults"], now["defaults"]) ++
            Settings.changed(before["enforced"], now["enforced"])
        )

      if keys != [] do
        Connections.broadcast("config.changed", %{
          "scope" => "org",
          "path" => kept["plane_url"],
          "keys" => keys
        })

        Organisation.reconfigure_all()
      end

      {:ok, Map.update!(kept, "path", &Troupe.Paths.display/1)}
    end
  end

  @doc "Ask the linked plane for the organisation's document now, and keep it."
  @spec refresh_organisation() :: :ok
  def refresh_organisation do
    with url when is_binary(url) <- Plane.url(),
         {:ok, answer} <- Plane.call("me.client_defaults", %{}),
         {:ok, _kept} <- keep_organisation(url, answer) do
      :ok
    else
      {:error, reason} ->
        Logger.info(
          "troupe-daemon: the organisation's document was not refreshed: #{inspect(reason)}"
        )

      _no_plane ->
        :ok
    end
  end

  @doc """
  Poll now, as the timer would: the handshake, then the signed answers where the plane's
  revision moved. Answers what changed: `:org`, `:versions`, both, or neither.
  """
  @spec poll(GenServer.server()) :: [:org | :versions]
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 60_000)

  # -- the poll -----------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    every =
      Keyword.get(opts, :poll_ms, Application.get_env(:troupe_gateway, :policy_poll_ms, @poll_ms))

    {:ok, schedule(%{every: every, revision: nil, versions: nil})}
  end

  @impl GenServer
  def handle_call(:poll, _from, state) do
    {changed, state} = asked(state)
    {:reply, changed, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    # While every client attached is in Local only the plane is not asked, and the next
    # poll after one that is not asks again; a link still asks at once, as it always did.
    {_changed, state} = if LocalOnly.paused?(), do: {[], state}, else: asked(state)
    {:noreply, schedule(state)}
  end

  defp asked(state) do
    if Plane.linked?() do
      _judged = Plane.handshake()
      revision = Plane.revision()

      if is_nil(revision) or revision != state.revision,
        do: fetched(%{state | revision: revision}),
        else: {[], state}
    else
      {[], %{state | revision: nil}}
    end
  end

  # The two signed answers, fetched because the revision moved. A plane from before the
  # revision names none, and is asked at its links alone, as before.
  defp fetched(%{revision: nil} = state), do: {[], state}

  defp fetched(state) do
    before = organisation()
    refresh_organisation()
    org = if organisation() != before, do: [:org], else: []

    {versions, state} = versions(state)
    {org ++ versions, state}
  end

  defp versions(state) do
    with url when is_binary(url) <- Plane.url(),
         {:ok, answer} <- Plane.call("me.client_versions", %{}),
         {:ok, body, _signed?} <- PlaneKeys.check(url, answer, "client_versions") do
      body = Map.delete(body, "signed")

      if state.versions != nil and body != state.versions,
        do: announce_versions(url, state.versions, body)

      {if(state.versions != nil and body != state.versions, do: [:versions], else: []),
       %{state | versions: body}}
    else
      {:error, reason} ->
        Logger.info("troupe-daemon: the version policy was not refreshed: #{format(reason)}")
        {[], state}

      _no_plane ->
        {[], state}
    end
  end

  defp announce_versions(url, before, now) do
    Connections.broadcast("config.changed", %{
      "scope" => "versions",
      "path" => PlaneKeys.plane(url),
      "keys" => Settings.changed(before, now)
    })
  end

  defp schedule(%{every: every} = state) when is_integer(every) and every > 0 do
    Process.send_after(self(), :poll, every)
    state
  end

  defp schedule(state), do: state

  # -- the copy -----------------------------------------------------------------------

  defp unsigned_line(plane_url, :unsigned) do
    Logger.info("troupe-daemon: " <> PlaneKeys.unsigned_line(plane_url, "client_defaults"))
  end

  defp unsigned_line(_plane_url, :signed), do: :ok

  defp signature(:signed, document), do: document["signed"]
  defp signature(:unsigned, _document), do: nil

  defp organisation do
    case Org.read_cache() do
      {:ok, cached} ->
        %{"defaults" => cached["defaults"] || %{}, "enforced" => cached["enforced"] || %{}}

      _none ->
        %{"defaults" => %{}, "enforced" => %{}}
    end
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
