defmodule Troupe.Plane.Breakglass do
  @moduledoc """
  Getting into the panel when the identity provider cannot let you in.

  The panel is behind OIDC, which is right until the day the reason you need the panel
  *is* the identity provider — a misconfigured client, an expired signing key, a tenant
  outage, or the first five minutes of a new installation when no group exists to be a
  platform admin of yet. Without a way in, the answer to "the IdP is down" is "edit the
  database", which is worse in every way than a door that is locked, logged and loud.

  So: one token, in a Kubernetes Secret, exchanged at `/admin/breakglass` for a session
  that is a platform admin and expires quickly.

  ## What it is not

  It is not a second identity system and it is not a wider role. A break-glass session
  is a `platform_admin` and nothing more — the same actor a member of the configured
  group gets — which matters because `Troupe.Plane.Admin` has no function that returns
  session content for *any* role. There is nothing here to escalate to. It cannot read a
  session, and neither can the person whose group membership it stands in for.

  ## Why it is safe enough, stated plainly

  The token lives in a Kubernetes Secret in `troupe-system`. Anyone who can read that
  Secret can already read the plane's database credential and its OpenBao role, so this
  grants no access that such a person did not already have. What it changes is that the
  access is now *usable through a browser*, which is why the rest of this module exists:

  * **Absent means gone.** No token configured and the routes 404. This is not a flag
    that defaults to on, and a deployment that never sets it has no door at all.
  * **Constant-time comparison**, so the token cannot be recovered a byte at a time.
  * **Short sessions.** A break-glass cookie carries its own expiry and is checked on
    every LiveView mount, so the way to end one is to wait rather than to remember.
  * **Audited both ways.** A success and a failure are both rows in `audit_events`, with
    the address they came from. The point of a break-glass door is that using it is
    conspicuous.
  * **Marked while you are in it.** The panel says so on every page, because an operator
    who has forgotten which session they are in is how a temporary door becomes the
    normal way in.

  It is deliberately not tied to a person. A token in a Secret is held by whoever holds
  the Secret, and pretending otherwise by asking for a username would make the audit
  trail say something it cannot know. `actor` is the string the audit records: `breakglass`
  unless the deployment names it something more specific.
  """

  alias Troupe.Plane.Audit

  # Not under `Web`: this is an authorisation decision, and the console reaches
  # authorisation only through `Troupe.Plane.Admin` — a LiveView that called a Web module
  # for its actor would be the private path into the plane that `mix troupe.boundaries`
  # exists to forbid. The controller in `Web.AdminAuth` calls this to *mint* a session;
  # `Admin.actor_for_session/1` is what reads one back.

  require Logger

  @default_subject "breakglass"
  @default_lifetime_seconds 3600

  @doc """
  Whether this deployment has a break-glass door at all.

  Everything else here is conditional on this, including whether the routes exist.
  """
  @spec configured?() :: boolean()
  def configured?, do: is_binary(token()) and token() != ""

  @doc """
  Check a token, and say who it makes you.

  `{:ok, subject, expires_at}` on a match. The expiry travels in the session rather than
  being recomputed later, so shortening the configured lifetime does not extend a session
  already open and lengthening it does not either.
  """
  @spec verify(String.t() | nil, keyword()) ::
          {:ok, String.t(), integer()} | {:error, :not_configured | :bad_token}
  def verify(offered, opts \\ [])

  def verify(offered, opts) when is_binary(offered) do
    case token() do
      nil ->
        {:error, :not_configured}

      "" ->
        {:error, :not_configured}

      expected ->
        if secure_compare(offered, expected) do
          now = Keyword.get(opts, :now, System.system_time(:second))
          {:ok, subject(), now + lifetime_seconds()}
        else
          {:error, :bad_token}
        end
    end
  end

  def verify(_offered, _opts), do: {:error, :bad_token}

  @doc """
  Whether a session's break-glass claim is still good.

  Read on every LiveView mount, for the same reason the role is: a cookie is a thing
  somebody is still holding, and the decision to let them in has to be re-made rather
  than remembered.
  """
  @spec live?(map(), keyword()) :: boolean()
  def live?(session, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    case {session["breakglass"], session["breakglass_expires_at"]} do
      {true, expires_at} when is_integer(expires_at) -> expires_at > now
      _other -> false
    end
  end

  @doc "The actor a break-glass session is. A platform admin, and no teams of its own."
  @spec actor(map()) :: Troupe.Plane.Admin.actor()
  def actor(session) do
    %{subject: session["subject"] || subject(), role: :platform_admin, teams: []}
  end

  @doc """
  Record that the door was used, or that somebody tried it.

  Both, and at `warning` for a failure: a break-glass endpoint being probed is a thing an
  operator should find in the log without going looking for it.
  """
  @spec record(:granted | :refused, String.t() | nil) :: :ok
  def record(outcome, address) do
    detail = %{"outcome" => to_string(outcome), "address" => address || "unknown"}
    {:ok, _event} = Audit.record(subject(), "admin.breakglass", subject(), detail, kind: "admin")

    case outcome do
      :granted -> Logger.warning("troupe plane: break-glass panel login from #{address}")
      :refused -> Logger.warning("troupe plane: break-glass token refused from #{address}")
    end

    :ok
  end

  @doc "How long a break-glass session lasts, in seconds."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds do
    case config()[:lifetime_seconds] do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_lifetime_seconds
    end
  end

  @doc "The subject a break-glass session runs as, which is what the audit records."
  @spec subject() :: String.t()
  def subject do
    case config()[:subject] do
      subject when is_binary(subject) and subject != "" -> subject
      _other -> @default_subject
    end
  end

  defp token, do: config()[:token]

  defp config, do: Application.get_env(:troupe_plane, :breakglass, [])

  # `:crypto.hash_equals/2` over digests rather than the raw strings, so that two tokens
  # of different lengths compare in the same time as two of the same length. Comparing
  # the strings directly would leak the length, which for a token is a real if small
  # head start.
  defp secure_compare(offered, expected) do
    :crypto.hash_equals(
      :crypto.hash(:sha256, offered),
      :crypto.hash(:sha256, expected)
    )
  end
end
