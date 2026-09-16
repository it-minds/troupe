defmodule Troupe.Plane.Fleet.SizeClass do
  @moduledoc """
  How demanding a session is here, as one word instead of seven numbers.

  The profile editor used to ask for `replicas`, `sessionsPerPod`, CPU and memory
  requests and limits, and disk size before it asked about anything an administrator
  actually wanted to configure. Seven fields, every one of them a guess, and the first
  of them a capacity question the plane already had the data to answer.

  All seven stay in the custom resource, because that is where infrastructure desired
  state belongs and the operator reads nothing else. They are derived here.

  ## Two classes, and they are about resources

  | class | sessions per worker | for |
  | --- | --- | --- |
  | `standard` | four | most work |
  | `heavy` | two | large repositories, builds, long or memory-hungry runs |

  **They are not about safety, and the console says so in those words.** Session-to-session
  file separation is already built: the mount table is resolved at create and recorded as
  a durable event, and `shell` runs under bubblewrap with only that session's mounts bound
  — another session's workspace is not in the namespace at all. Two sessions on one worker
  cannot reach each other's files whether they belong to one person or two.

  So there is no isolated class, and adding one would buy kernel separation nobody needs
  at the cost of a cold start per session. `sessionsPerPod: 1` stays available in the
  custom resource for anyone who ever does need it, and does not appear on the admin
  surface.

  ## The numbers stay inside the default policy

  A `TroupePolicy` is a cluster admin's document and the plane cannot write it. Both
  classes are chosen to sit under the shipped defaults — sixteen sessions per pod, four
  CPUs, eight gibibytes — so a deployment that has never written a policy gets both
  classes, and one that has written a tighter policy refuses the class that exceeds it at
  admission, which is where refusals about infrastructure belong.
  """

  @classes %{
    "standard" => %{
      sessions_per_pod: 4,
      # Requests are a scheduling floor, not an allowance: a worker that asked for its
      # limit would be a worker two of which will not fit on a node that could run four.
      requests: %{"cpu" => "250m", "memory" => "1Gi"},
      limits: %{"cpu" => "2", "memory" => "4Gi"},
      storage_size: "20Gi",
      summary: "Several sessions share a worker. Right for most work."
    },
    "heavy" => %{
      sessions_per_pod: 2,
      requests: %{"cpu" => "1", "memory" => "4Gi"},
      limits: %{"cpu" => "4", "memory" => "8Gi"},
      storage_size: "100Gi",
      summary:
        "Fewer sessions per worker, with more CPU, memory and disk each. For large repositories, builds, and long or memory-hungry runs. This is about resources: sessions already cannot see each other's files, whatever the class."
    }
  }

  @default "standard"

  @type t :: String.t()

  @doc "Every class, by name."
  @spec all() :: %{String.t() => map()}
  def all, do: @classes

  @doc "The names, in the order a console offers them."
  @spec names() :: [String.t()]
  def names, do: ["standard", "heavy"]

  @doc "The class a profile gets when nobody chooses."
  @spec default() :: t()
  def default, do: @default

  @doc "Whether this is a class."
  @spec valid?(term()) :: boolean()
  def valid?(name), do: is_map_key(@classes, name)

  @doc "One class, or the default."
  @spec get(term()) :: map()
  def get(name) when is_map_key(@classes, name), do: @classes[name]
  def get(_other), do: @classes[@default]

  @doc "How many sessions fit on one worker of this class."
  @spec sessions_per_pod(term()) :: pos_integer()
  def sessions_per_pod(name), do: get(name).sessions_per_pod

  @doc """
  The spec fields this class decides, as the custom resource spells them.

  Merged *over* whatever the profile's own spec map holds, so a class is the answer and
  a hand-written override is not quietly kept: the whole point of the class is that
  these seven numbers have one source.
  """
  @spec spec(term()) :: map()
  def spec(name) do
    class = get(name)

    %{
      "sessionsPerPod" => class.sessions_per_pod,
      "resources" => %{"requests" => class.requests, "limits" => class.limits},
      "storage" => %{"size" => class.storage_size}
    }
  end

  @doc """
  The class a profile written before there were classes belongs to.

  By what it was already doing: a profile packing several sessions onto a worker was
  standard whatever its resources said, and one running them nearly alone was heavy.
  Derived rather than defaulted, so an administrator who had set this up by hand does
  not find their careful `sessionsPerPod: 1` silently turned into four.
  """
  @spec of_sessions_per_pod(integer() | nil) :: t()
  def of_sessions_per_pod(n) when is_integer(n) and n <= 2, do: "heavy"
  def of_sessions_per_pod(_n), do: @default
end
