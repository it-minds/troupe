defmodule Troupe.Plane.Breakglass do
  @moduledoc """
  Administering the plane when the identity provider cannot let you in.

  The console and `troupe admin` sign in through OIDC, which is right until the day the
  reason you need them *is* the identity provider — a misconfigured client, an expired
  signing key, a tenant outage, or the first five minutes of a new installation when no
  group exists to be a platform admin of yet. Without a way in, the answer to "the IdP is
  down" is "edit the database", which is worse in every way than a door that is locked,
  logged and loud.

  So: one token, in a Kubernetes Secret, exchanged at `POST /auth/breakglass` for a plane
  token that is a platform admin and expires quickly. That plane token is what the console
  and `troupe admin` hold; it carries a `breakglass` claim, so every surface that reads it
  knows what it is without a lookup. It is the one door: the form the plane's own console
  had at `/admin/breakglass` went with that console.

  ## What it is not

  It is not a second identity system and it is not a wider role. A break-glass token is a
  `platform_admin` and nothing more — the same actor a member of the configured group
  gets — which matters because `Troupe.Plane.Admin` has no function that returns session
  content for *any* role. There is nothing here to escalate to. It cannot read a session,
  and neither can the person whose group membership it stands in for.

  ## Why it is safe enough, stated plainly

  The token lives in a Kubernetes Secret in `troupe-system`. Anyone who can read that
  Secret can already read the plane's database credential and its OpenBao role, so this
  grants no access that such a person did not already have. What it changes is that the
  access is now *usable from a browser or a terminal*, which is why the rest of this
  module exists:

  * **Absent means gone.** No token configured and the route 404s. This is not a flag
    that defaults to on, and a deployment that never sets it has no door at all.
  * **Constant-time comparison**, so the token cannot be recovered a byte at a time.
  * **Short sessions.** A break-glass plane token ends at its `exp`, and nothing refreshes
    it, so the way to end one is to wait rather than to remember. It lasts the configured
    lifetime or the fifteen minutes the protocol lets any plane token last, whichever is
    shorter: the door never makes a longer token than sign-in does, and when the quarter
    hour is up the operator types the token again.
  * **Administration only.** At `/rpc` the token may call the `admin.*` methods and `me`
    and nothing else: it has no sessions, no memory and no machine of its own, and the
    harness methods that would look those up by subject could find a person's whose
    subject happens to match the name the deployment gave the door.
  * **Audited both ways.** A success and a failure are both rows in `audit_events`, with
    the address they came from. The point of a break-glass door is that using it is
    conspicuous.
  * **Marked while you are in it.** `me` answers `breakglass: true` for the token, and the
    console says so on every page, because an operator who has forgotten which session
    they are in is how a temporary door becomes the normal way in.

  It is deliberately not tied to a person. A token in a Secret is held by whoever holds
  the Secret, and pretending otherwise by asking for a username would make the audit
  trail say something it cannot know. `actor` is the string the audit records: `breakglass`
  unless the deployment names it something more specific.
  """

  alias Troupe.Plane.{Audit, Identity}
  alias Troupe.Protocol.Token

  # Not under `Web`: this is an authorisation decision, and the router calls it to *mint*
  # a token while `Admin.actor_for/1` is what reads one back from its claims. A door that
  # lived in a Web module would be one the admin surface could not reason about.

  require Logger

  @default_subject "breakglass"

  @doc """
  Whether this deployment has a break-glass door at all.

  Everything else here is conditional on this, including whether the routes exist.
  """
  @spec configured?() :: boolean()
  def configured?, do: is_binary(token()) and token() != ""

  @doc """
  Check a token, and say who it makes you.

  `{:ok, subject, expires_at}` on a match. The expiry is fixed here, when the token is
  checked, so shortening the configured lifetime does not end a token already minted and
  lengthening it does not extend one either; it is the minted token's `exp`.
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
  The claims a break-glass plane token carries beyond the ones every plane token has.

  The claim, and not a recognisable subject, is what makes the token a break-glass one:
  the subject is whatever the deployment named it, and a person at the identity provider
  could carry the same name. Only the plane mints with this claim, after `verify/2`.
  """
  @spec claims(String.t()) :: map()
  def claims(subject) when is_binary(subject) do
    %{"sub" => subject, "name" => subject, "breakglass" => true}
  end

  @doc "Whether a plane token's claims are a break-glass token's."
  @spec token?(map()) :: boolean()
  def token?(claims) when is_map(claims), do: claims["breakglass"] == true
  def token?(_claims), do: false

  @doc """
  The user a break-glass token is, from its claims and nothing in the database.

  Not a row: a token in a Secret is held by whoever holds the Secret, and a row would
  say somebody in particular was here. `kind: "breakglass"` is what `Identity` and
  `Admin` key on, the way they key on a principal's `"service"`: no groups, no teams,
  no profiles, and the platform-admin role for as long as the token lasts.
  """
  @spec user(map()) :: Identity.User.t()
  def user(claims) when is_map(claims) do
    subject =
      case claims["sub"] do
        name when is_binary(name) and name != "" -> name
        _unnamed -> subject()
      end

    %Identity.User{
      id: nil,
      subject: subject,
      display_name: subject,
      email: nil,
      active: true,
      kind: "breakglass"
    }
  end

  @doc """
  The actor a break-glass token is. A platform admin, and no teams of its own.

  From a token's claims (`sub`) or from the shape `Admin.actor_for/1` hands over
  (`subject`); the configured name only where neither says.
  """
  @spec actor(map()) :: Troupe.Plane.Admin.actor()
  def actor(claims) do
    %{
      subject: claims["sub"] || claims["subject"] || subject(),
      role: :platform_admin,
      teams: []
    }
  end

  @doc "Whether a resolved user is a break-glass token's, which may administer and no more."
  @spec user?(Identity.User.t() | term()) :: boolean()
  def user?(%Identity.User{kind: "breakglass"}), do: true
  def user?(_user), do: false

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
      :granted -> Logger.warning("troupe plane: break-glass token accepted from #{address}")
      :refused -> Logger.warning("troupe plane: break-glass token refused from #{address}")
    end

    :ok
  end

  @doc """
  How long a break-glass token lasts, in seconds.

  The configured lifetime where one is set, and never more than the protocol lets any
  plane token last, which is what the door makes of a value above it and what it uses
  where none is set.
  """
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds do
    ceiling = Token.max_lifetime_seconds()

    case config()[:lifetime_seconds] do
      n when is_integer(n) and n > 0 -> min(n, ceiling)
      _other -> ceiling
    end
  end

  @doc "The subject a break-glass token runs as, which is what the audit records."
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
