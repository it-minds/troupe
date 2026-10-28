defmodule Troupe.Gateway.Artifacts do
  @moduledoc """
  Publishing an artifact on the plane from this machine (#62), as its person, with this
  daemon's sign-in: what `publish_artifact` sends from a session running here (`publish/2`,
  installed as `Troupe.Artifacts`'s host when the daemon starts), and what a client's
  "Publish…" sends (`artifact.publish`, through `put/1`).

  The plane's `artifact.publish` takes it as it is, the session it came from and the agent
  that called the tool named as its provenance. Signed out, there is nowhere to send it, and
  the answer says so; the tool then says where the file is.

  A version too large for one call (the plane's door takes 4 MiB of body, and base64 makes a
  file a third larger) goes by an upload handle: `artifact.upload.begin` names the files and
  their sizes, each goes straight to the object store at the URL the plane presigned for it,
  and the publish names the handle instead of carrying the files.

  `list/1` is the person's own artifacts on the plane, for a client's "Publish a new version
  of…", with where the console's gallery is. `forward/2` is what the desktop app's gallery
  and viewer ask of one artifact, each the plane's method of the same name.
  """

  alias Troupe.Gateway.{LocalOnly, Memory, Plane}

  @keys ~w(title kind visibility owner files id note session_id agent)

  # What one call carries inline at most, in base64: under the plane's door with room for the
  # rest of the request.
  @inline_bytes 2_500_000

  @doc """
  Install this daemon as where its sessions' artifacts go, and as the answer to whether one
  of them can publish now: when this daemon is signed in to a plane.
  """
  @spec install() :: :ok
  def install, do: Troupe.Artifacts.install(&__MODULE__.publish/2, ready: &__MODULE__.signed_in?/1)

  @doc "Whether a session here can publish now: this daemon is signed in to a plane."
  @spec signed_in?(String.t() | nil) :: boolean()
  def signed_in?(_session_id) do
    is_binary(Plane.url()) and Plane.linked?()
  catch
    # No plane process (a daemon still starting): nothing to publish to yet.
    :exit, _reason -> false
  end

  @doc "What `publish_artifact` sends from a session here: `put/1`, naming the session and its agent."
  @spec publish(map(), Troupe.Tool.Ctx.t()) :: {:ok, map()} | {:error, :signed_out | String.t()}
  def publish(params, ctx) do
    # A session under its client's Local only sends nothing to the plane (`LocalOnly`).
    if LocalOnly.session?(ctx.session_id),
      do:
        {:error,
         "this session is under Local only, so nothing of it is published on the plane; " <>
           "the file stays in the workspace"},
      else: send_publish(params, ctx)
  end

  defp send_publish(params, ctx) do
    params
    |> Map.put("session_id", ctx.session_id)
    |> Map.put("agent", agent(ctx))
    |> put()
    |> case do
      {:ok, artifact} -> {:ok, artifact}
      {:error, :signed_out} -> {:error, :signed_out}
      {:error, reason} -> {:error, Memory.sentence(reason)}
    end
  end

  @doc "Publish `params` on the linked plane as this daemon's person: the plane's answer."
  @spec put(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def put(params) do
    with url when is_binary(url) <- Plane.url(),
         true <- Plane.linked?(),
         {:ok, params} <- carried(Map.take(params, @keys), &Plane.call("artifact.upload.begin", %{"files" => &1})),
         {:ok, artifact} <- Plane.call("artifact.publish", params) do
      {:ok, Map.put(artifact, "plane_url", url)}
    else
      {:error, :unlinked} -> {:error, :signed_out}
      {:error, reason} -> {:error, reason}
      _signed_out -> {:error, :signed_out}
    end
  end

  @doc "The person's own artifacts on the linked plane, and the gallery's address."
  @spec list(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def list(params) do
    with url when is_binary(url) <- Plane.url(),
         true <- Plane.linked?(),
         {:ok, answer} <-
           Plane.call("artifact.list", Map.take(params, ~w(mine shared teams visibility))) do
      {:ok, Map.put(answer, "plane_url", url)}
    else
      {:error, :unlinked} -> {:error, :signed_out}
      {:error, reason} -> {:error, reason}
      _signed_out -> {:error, :signed_out}
    end
  end

  # What a client's gallery and viewer ask of one artifact, each the plane's own method with
  # the arguments it takes, nothing else of what the client sent: one with its versions, a
  # ticket to open it or one version on its host, a view or edit link and its revoking, a
  # rollback and a pin. The plane decides who may: the owner, an edit link's holder, a reader.
  @forwarded %{
    "artifact.get" => ~w(id),
    "artifact.open" => ~w(id version),
    # One text file of a version, for the terminal's frame.
    "artifact.read" => ~w(id version path),
    "artifact.share" => ~w(id role expires),
    "artifact.unshare" => ~w(id share person),
    "artifact.rollback" => ~w(id version),
    "artifact.pin" => ~w(id version),
    # Who may open it, moved by its owner (or its title): a put over a version, no files sent.
    "artifact.put" => ~w(id base visibility title note),
    # Whose it is: handed to a team the person is in, or taken back (`to: "me"`) by an admin
    # of that team or a platform admin; the plane decides, as for every method here.
    "artifact.transfer" => ~w(id to)
  }

  @doc "The methods `forward/2` sends to the plane."
  @spec forwarded() :: [String.t()]
  def forwarded, do: Map.keys(@forwarded)

  @doc """
  One of `forwarded/0`, sent to the linked plane as this daemon's person: the plane's answer
  with `plane_url`, or its refusal as it gave it (`{:rpc, error}`).
  """
  @spec forward(String.t(), map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def forward(method, params) when is_map_key(@forwarded, method) do
    with url when is_binary(url) <- Plane.url(),
         true <- Plane.linked?(),
         {:ok, answer} <- Plane.call(method, Map.take(params, @forwarded[method])) do
      {:ok, Map.put(answer, "plane_url", url)}
    else
      {:error, :unlinked} -> {:error, :signed_out}
      {:error, reason} -> {:error, reason}
      _signed_out -> {:error, :signed_out}
    end
  end

  @doc """
  `params` as a publish sends them: inline where its files fit in one call; else by an
  upload handle, `begin` asked for one with each file's path and size, the files sent to
  the object store first and the publish naming the handle. A daemon begins with the plane's
  `artifact.upload.begin`, a pod with `session.artifact.upload.begin` over its control link.
  """
  @spec carried(map(), ([map()] -> {:ok, map()} | {:error, term()})) :: {:ok, map()} | {:error, term()}
  def carried(%{"files" => files} = params, begin) when is_list(files) do
    inline = files |> Enum.map(&byte_size(&1["bytes"] || "")) |> Enum.sum()

    if inline <= @inline_bytes,
      do: {:ok, params},
      else: upload(params, files, begin)
  end

  def carried(params, _begin), do: {:ok, params}

  defp upload(params, files, begin) do
    with {:ok, decoded} <- decode(files),
         {:ok, %{"upload" => handle, "urls" => urls}} <- begin.(Enum.map(decoded, &announce/1)),
         :ok <- send_all(decoded, urls) do
      {:ok, params |> Map.delete("files") |> Map.put("upload", handle)}
    end
  end

  defp decode(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case Base.decode64(file["bytes"] || "", ignore: :whitespace) do
        {:ok, body} -> {:cont, {:ok, [Map.put(file, "body", body) | acc]}}
        :error -> {:halt, {:error, "#{file["path"]}'s bytes are not base64"}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp announce(file) do
    %{"path" => file["path"], "size" => byte_size(file["body"])}
    |> then(&if(file["content_type"], do: Map.put(&1, "content_type", file["content_type"]), else: &1))
  end

  defp send_all(files, urls) do
    by_path = Map.new(urls, &{&1["path"], &1["url"]})

    Enum.reduce_while(files, :ok, fn file, :ok ->
      case Req.put(by_path[file["path"]] || "", body: file["body"], retry: false, decode_body: false) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:cont, :ok}

        {:ok, %{status: status}} ->
          {:halt, {:error, "the object store refused #{file["path"]} (HTTP #{status})"}}

        {:error, reason} ->
          {:halt, {:error, "#{file["path"]} could not be sent to the object store (#{inspect(reason)})"}}
      end
    end)
  end

  defp agent(%{definition: %{name: name}}) when is_binary(name), do: "agent:" <> name
  defp agent(%{agent_path: [_ | _] = path}), do: "agent:" <> List.last(path)
  defp agent(_ctx), do: nil
end
