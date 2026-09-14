defmodule Troupe.Identity do
  @moduledoc """
  Who the person at this machine is, when they have said.

  A local daemon authenticates by the socket's permissions or by a token in a file only
  the user can read. Either way it knows *a* user — the operating system's — and calls
  them `local:<username>`. That is enough while the sessions never leave the machine,
  and not enough the moment they do: a session that will be listed by a plane, billed to
  a team, or opened from another device has to name the person the identity provider
  knows, and the daemon cannot work that out on its own.

  So a client that is signed in tells it, once. `identity.link` records the subject the
  provider issued, the display name, and which plane it was signed into; from then on
  every actor in every log is that person rather than a username that means nothing
  anywhere else. `identity.unlink` puts it back.

  What this is *not*: authentication. Nothing here verifies a token, and nothing should
  — the daemon's trust boundary is the file mode on its socket, and a client that can
  reach it can already do everything. Linking is a *label*, applied by somebody who has
  already been admitted, so that what they do is recorded under a name that survives
  leaving this computer. A daemon reachable by somebody who should not be linking is a
  daemon with a much larger problem than the label.

  Stored as `<state>/identity.json`, `0600`, beside the sessions it names.
  """

  @enforce_keys [:subject]
  defstruct [:subject, :display_name, :plane_url, :linked_at]

  @type t :: %__MODULE__{
          subject: String.t(),
          display_name: String.t() | nil,
          plane_url: String.t() | nil,
          linked_at: String.t() | nil
        }

  @doc "Where the link is recorded."
  @spec path(Path.t() | nil) :: Path.t()
  def path(state_dir \\ nil), do: Path.join(Troupe.Paths.state_dir(state_dir), "identity.json")

  @doc """
  The linked identity, or `nil`.

  Read from disk each time rather than cached: a link made through one connection has to
  be true for the next one, and a daemon that remembered the answer would go on calling
  somebody by their old name until it was restarted.
  """
  @spec get(Path.t() | nil) :: t() | nil
  def get(state_dir \\ nil) do
    with {:ok, contents} <- File.read(path(state_dir)),
         {:ok, %{"subject" => subject} = json} when is_binary(subject) <- Jason.decode(contents) do
      %__MODULE__{
        subject: subject,
        display_name: json["display_name"],
        plane_url: json["plane_url"],
        linked_at: json["linked_at"]
      }
    else
      _ -> nil
    end
  end

  @doc """
  Record who this machine's sessions belong to.

  Refuses a blank subject, because the whole value of the record is that it names
  somebody a provider would recognise.
  """
  @spec link(map(), Path.t() | nil) :: {:ok, t()} | {:error, :invalid_subject}
  def link(attrs, state_dir \\ nil) do
    case attrs["subject"] || attrs[:subject] do
      subject when is_binary(subject) and subject != "" ->
        identity = %__MODULE__{
          subject: subject,
          display_name: attrs["display_name"] || attrs[:display_name],
          plane_url: attrs["plane_url"] || attrs[:plane_url],
          linked_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }

        write!(identity, state_dir)
        {:ok, identity}

      _ ->
        {:error, :invalid_subject}
    end
  end

  @doc "Forget it. The sessions already logged keep the actor they were written with."
  @spec unlink(Path.t() | nil) :: :ok
  def unlink(state_dir \\ nil) do
    File.rm(path(state_dir))
    :ok
  end

  @doc """
  The principal a local connection should carry.

  The linked person if there is one, and the operating system's user otherwise. `kind`
  stays `user` in both cases — what changes is whether the subject means anything off
  this machine.
  """
  @spec principal(String.t(), Path.t() | nil) :: map()
  def principal(os_user, state_dir \\ nil) do
    case get(state_dir) do
      nil ->
        %{"subject" => "local:" <> os_user, "display_name" => os_user, "kind" => "user"}

      %__MODULE__{} = identity ->
        %{
          "subject" => identity.subject,
          "display_name" => identity.display_name || identity.subject,
          "kind" => "user",
          "linked" => true
        }
    end
  end

  @doc "The link as a client sees it."
  @spec to_json(t() | nil) :: map()
  def to_json(nil), do: %{"linked" => false}

  def to_json(%__MODULE__{} = identity) do
    %{
      "linked" => true,
      "subject" => identity.subject,
      "display_name" => identity.display_name,
      "plane_url" => identity.plane_url,
      "linked_at" => identity.linked_at
    }
  end

  defp write!(%__MODULE__{} = identity, state_dir) do
    file = path(state_dir)
    File.mkdir_p!(Path.dirname(file))

    File.write!(
      file,
      Jason.encode!(%{
        "subject" => identity.subject,
        "display_name" => identity.display_name,
        "plane_url" => identity.plane_url,
        "linked_at" => identity.linked_at
      })
    )

    # Nothing secret is in here, but it names a person and sits beside their sessions.
    File.chmod!(file, 0o600)
  end
end
