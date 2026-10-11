defmodule Troupe.Plane.Triggers.Notify do
  @moduledoc """
  Telling somebody else's system that a run finished, without becoming their way in.

  A trigger may name a URL the plane posts to when one of its runs reaches a terminal
  state. That is a request the plane makes, holding the plane's own network position,
  at a target somebody with `admin.trigger.put` chose — which is the shape of every
  server-side request forgery there has ever been.

  ## What the target must be

  **Absolute.** A relative target is the one this exists to refuse. LangGraph shipped an
  advisory in 2026 for exactly it: a webhook target of `/rpc` was resolved against the
  server's own base URL and reached an in-process route with no authentication at all,
  because the request never left the process that was trusted. Here a URL with no scheme
  and no host is not a URL, and is refused before it is stored.

  **Not loopback, not link-local, not a cloud's metadata service.**
  `http://127.0.0.1:4000/rpc` is the same attack written out in full, and
  `http://169.254.169.254/` is the cloud metadata endpoint, which is where credentials
  live. Two clouds answer outside link-local too, at `fd00:ec2::254` and
  `100.100.100.200`. All of them are refused by address, so a hostname that resolves to
  one is refused as surely as a literal. The list is the one a worker is held to
  (`Troupe.WorkerProfile.Reach.refusal/1`, Decision 856), so an address added there is
  refused here as well (Decision 866).

  Other private ranges are *not* refused here. A plane in a cluster has legitimate
  internal targets on private addresses — somebody's own webhook receiver in the next
  namespace — and refusing 10/8 outright would break them. What governs those is the
  egress allowlist, which an administrator sets deliberately. The shared address space,
  `100.64.0.0/10`, is the exception: one metadata service answers in it and other
  internal services of a provider may, and the plane's own egress is not restricted.

  **On the egress allowlist.** The same list a pod's egress is held to. A plane that
  could reach hosts its own workers cannot would be the widest hole in the deployment,
  and it would be one nobody was looking at.

  ## Twice, because a name is not an address

  Checked when the trigger is saved, which is where an administrator finds out; and
  again at send, where the hostname is resolved and every address it answers with is
  checked. A host that passed at save and answers `127.0.0.1` today is a DNS rebind, and
  the check that catches it is the second one. A check only at save is a check against
  the value, not against what the value does.

  And the request goes to the address that second check passed, not to whatever the name
  answers when the connection asks again: a name answering one address to the check and
  another a moment later (a rebind with a short lifetime, a round robin) would otherwise be
  sent to where no check looked. The name still goes as the `Host` header, the TLS server
  name and the name the certificate is checked against (Decision 866).
  """

  alias Troupe.Plane.ClusterPolicy
  alias Troupe.Plane.Triggers.{Run, Trigger}
  alias Troupe.Protocol.Error
  alias Troupe.WorkerProfile.Reach

  require Logger

  @schemes ~w(http https)
  @timeout 5_000

  @doc """
  Whether a URL may be a notification target, without asking DNS.

  What `Trigger.changeset/2` calls: a check an administrator gets an answer to while
  they are still looking at the form.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok
  def validate(""), do: :ok

  def validate(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme not in @schemes ->
        {:error, "is an absolute http or https URL"}

      %URI{host: host} when host in [nil, ""] ->
        # The advisory's case. A target of `/trigger/x` parses without a host, would be
        # resolved against whatever base the sender happened to hold, and would reach a
        # route inside the plane with the plane's own authority.
        {:error, "is absolute: it names a host, and a path alone is not a target"}

      %URI{host: host} ->
        host_allowed(host)
    end
  end

  def validate(_other), do: {:error, "is a string"}

  @doc """
  Whether the plane may send to this URL *now*: the same checks, plus what DNS says.

  Separate from `validate/1` because it talks to the network, which a changeset must
  not, and because the answer can differ from the one given at save — which is the
  whole reason it is asked a second time.
  """
  @spec allowed?(String.t()) :: :ok | {:error, String.t()}
  def allowed?(url) do
    with {:ok, _address} <- target(url), do: :ok
  end

  @doc """
  Post a run's outcome to its trigger's target, if it has one and the target is allowed.

  The body is lifecycle and never content: which trigger, which run, which session, how
  it ended. Somebody who wants to know what the session *said* has a session id and a
  credential to read it with, which is a different question with a different answer.

  Every refusal is logged and none raises. A notification is the last thing that happens
  to a run, and a run that failed because its notification could not be sent would be a
  worse record than one that merely was not announced.
  """
  @spec deliver(Trigger.t(), Run.t(), map()) :: :ok | {:error, String.t()}
  def deliver(%Trigger{notify_url: url}, _run, _outcome) when url in [nil, ""], do: :ok

  def deliver(%Trigger{notify_url: url} = trigger, %Run{} = run, outcome) do
    case target(url) do
      {:ok, address} ->
        post(url, address, body(trigger, run, outcome))

      {:error, reason} ->
        # Refused at send even though it was allowed at save. Worth a warning rather than
        # a debug line: either the allowlist narrowed under a trigger nobody has edited
        # since, or a name the plane trusted now answers with an address it does not.
        Logger.warning(
          "troupe plane: trigger #{trigger.name} will not notify #{url}: #{reason}"
        )

        {:error, reason}
    end
  end

  @doc "The same refusal as an `Error`, for the surfaces that answer with one."
  @spec error(String.t()) :: Error.t()
  def error(reason), do: Error.new(:forbidden, %{field: "notify_url", reason: reason})

  # -- the checks -------------------------------------------------------------

  # Both halves, in the order that gives the most useful refusal: what the host *is*
  # before what the policy thinks of it, because "that is loopback" tells an
  # administrator something and "that is not on the allowlist" would not.
  defp host_allowed(host) do
    with :ok <- spelled_allowed(host), do: policy_allows(host)
  end

  # What the URL says, before anybody asks DNS. `:inet.parse_address/1` answers for both
  # families, so `[::1]` is caught as surely as `127.0.0.1`; a host that is a name is
  # checked for the two spellings of loopback that need no lookup.
  defp spelled_allowed(host) do
    case parse_address(host) do
      {:ok, address} -> address_allowed(address)
      :error -> name_allowed(host)
    end
  end

  defp name_allowed("localhost"), do: {:error, "is not loopback"}

  defp name_allowed(host) do
    if String.ends_with?(host, ".localhost"),
      do: {:error, "is not loopback"},
      else: :ok
  end

  # The same list a pod's egress is held to. A literal address is passed to it as
  # written: a policy that names hosts does not match an address, which is the right
  # answer — an administrator who means to allow one says so.
  defp policy_allows(host) do
    if ClusterPolicy.egress_allowed?(host),
      do: :ok,
      else: {:error, "is a host this deployment's egress policy allows"}
  end

  # The address to send to: the first the host answers, once every answer has passed.
  # The first is a v4 one when there is one, as the connection would have chosen.
  defp target(url) do
    with :ok <- validate(url),
         %URI{host: host} <- URI.parse(url),
         :ok <- host_allowed(host) do
      case addresses(host) do
        [] -> {:error, "is a host that resolves"}
        [first | _rest] = addresses -> Enum.find_value(addresses, {:ok, first}, &refusal/1)
      end
    end
  end

  defp refusal(address) do
    case address_allowed(address) do
      :ok -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  # A literal is already an address and needs no lookup. A name that resolves to nothing
  # is refused by the caller rather than treated as reachable.
  defp addresses(host) do
    case parse_address(host) do
      {:ok, address} -> [address]
      :error -> host |> strip_brackets() |> resolve()
    end
  end

  # What DNS answers for a name, in both families. `:notify_resolver` in the application
  # environment, a function of a hostname to its addresses, stands in for DNS where a test
  # must say what a name answers without asking the network.
  defp resolve(host) do
    case Application.get_env(:troupe_plane, :notify_resolver) do
      fun when is_function(fun, 1) ->
        fun.(host)

      nil ->
        for family <- [:inet, :inet6],
            {:ok, list} <- [:inet.getaddrs(String.to_charlist(host), family)],
            address <- list,
            do: address
    end
  end

  defp parse_address(host) do
    case host |> strip_brackets() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, address} -> {:ok, address}
      {:error, :einval} -> :error
    end
  end

  # What no worker reaches, the plane does not post to: loopback, the unspecified
  # address, link-local and the metadata addresses, from the one list
  # `Troupe.WorkerProfile.Reach` keeps (not `Troupe.Plane.Reach`, which asks it of profiles).
  # A v4 address wearing a v6 hat (`::ffff:127.0.0.1`, `64:ff9b::a9fe:a9fe`), which is the
  # one that gets past a check written only for the eight-tuple, is judged as the v4
  # address it names, here as there.
  defp address_allowed(address) do
    address = Reach.ipv4(address)

    case Reach.refusal(address) do
      nil -> beyond_reach(address)
      kind -> {:error, said(kind)}
    end
  end

  defp said("unspecified"), do: "is not the unspecified address"
  defp said("cloud metadata"), do: "is not a cloud metadata address"
  defp said(kind), do: "is not #{kind}"

  # And what is the plane's own to refuse. Multicast in both families, `ff00::/8` written
  # as a range; and the shared address space, `100.64.0.0/10`: a worker reaches it only at
  # an address it was given (Decision 856), and the chart leaves the plane's egress open.
  defp beyond_reach({a, _b, _c, _d}) when a >= 224, do: {:error, "is not multicast"}

  defp beyond_reach({100, b, _c, _d}) when b in 64..127,
    do: {:error, "is not in the shared address space"}

  defp beyond_reach({a, _b, _c, _d, _e, _f, _g, _h}) when a >= 0xFF00,
    do: {:error, "is not multicast"}

  defp beyond_reach(_address), do: :ok

  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(host), do: host

  # -- sending ----------------------------------------------------------------

  defp body(trigger, run, outcome) do
    %{
      "trigger" => trigger.name,
      "run" => run.idempotency_key,
      "source" => run.source,
      "session_id" => run.session_id,
      "fired_at" => DateTime.to_iso8601(run.fired_at),
      "state" => outcome["state"],
      "done_reason" => outcome["done_reason"],
      "failed_reason" => outcome["failed_reason"]
    }
  end

  defp post(url, address, body) do
    options =
      Keyword.merge(
        [
          method: :post,
          url: url,
          json: body,
          retry: false,
          receive_timeout: @timeout,
          # No redirects. A target that answers `302 http://127.0.0.1/` would carry the
          # request somewhere neither check ever saw, which would make both of them
          # decoration.
          redirect: false
        ],
        pinned(URI.parse(url), address)
      )

    case Req.request(options) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, "answered #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # The URL names the address that was checked, so the connection asks DNS nothing and
  # cannot be answered differently; a literal in an older spelling is written as the
  # address it was read as. A name still goes as the `Host` header, the TLS server name
  # and the name the certificate is checked against (Mint's `:hostname`).
  defp pinned(%URI{host: host, scheme: scheme, port: port} = uri, address) do
    url = %{uri | host: to_string(:inet.ntoa(address))}

    case parse_address(host) do
      {:ok, _literal} ->
        [url: url]

      :error ->
        named = if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
        [url: url, headers: [{"host", named}], connect_options: [hostname: host]]
    end
  end
end
