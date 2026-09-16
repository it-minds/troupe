defmodule Troupe.E2E.World do
  @moduledoc """
  A cluster, and the things a test is allowed to do to it.

  A *world* is a setup that creates concrete resources and owns exactly what it created.
  This one attaches to a cluster `scripts/remote-up` already built and never makes one:
  a suite that could bring up its own cluster is a suite that quietly rebuilds the thing
  it was supposed to be testing, and the first time the chart was wrong it would say so
  by taking four minutes longer rather than by failing.

  So everything here is either a read, or a change that names what it will undo.

  ## Why shelling out to kubectl

  The operator holds a `k8s` client and could use it. It is deliberately not used here.
  What these tests assert is what a cluster administrator would see — `kubectl get`,
  `kubectl delete pod`, `kubectl exec` — and asserting it through the same library the
  operator uses would make a whole class of failure invisible: a wrong RBAC rule, a
  missing CRD field, an object the operator believes it wrote. A separate road to the
  same API server is the point.

  ## The rule that runs through the suite

  **A passing response is not proof that an action was blocked.** Every negative claim
  here is proven by an independent witness — `exec` into the pod and watch the connection
  fail, read the transcript the fake provider wrote — never by the presence of a
  `NetworkPolicy` object or the absence of an error.
  """

  @namespace "troupe-system"
  @plane "http://plane.localtest.me:30080"
  @dex "http://dex.localtest.me:30080/dex"
  @a2a "http://a2a.localtest.me:30080"

  @doc "The namespace the chart is installed into."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc "The worker namespace for a profile. The operator makes it; nothing here does."
  @spec worker_namespace(String.t()) :: String.t()
  def worker_namespace(profile), do: "troupe-w-#{profile}"

  @doc "The profile `scripts/remote-up` creates, or whichever one this run was told about."
  @spec profile() :: String.t()
  def profile, do: System.get_env("TROUPE_PROFILE_NAME") || "dev"

  @doc "Where the plane answers, through the cluster's ingress."
  @spec plane_url() :: String.t()
  def plane_url, do: System.get_env("TROUPE_E2E_PLANE_URL") || @plane

  @doc "Where the A2A facade answers, through the cluster's ingress."
  @spec a2a_url() :: String.t()
  def a2a_url, do: System.get_env("TROUPE_E2E_A2A_URL") || @a2a

  @doc "Where the identity provider answers. The same URL inside the cluster and out."
  @spec issuer() :: String.t()
  def issuer, do: System.get_env("TROUPE_E2E_ISSUER") || @dex

  @doc """
  Run kubectl against the context this run was pinned to, and give back what it said.

  The context comes from `mix troupe.e2e`, which checked it before anything got this far.
  Never from `KUBECONFIG` alone, so that a suite mid-run cannot follow a context switch
  somewhere else on the machine.
  """
  @spec kubectl([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def kubectl(args, opts \\ []) do
    System.cmd("kubectl", ["--context", context() | args],
      stderr_to_stdout: Keyword.get(opts, :stderr, true)
    )
  end

  @doc "The same, raising with the output when it fails. Most calls want this."
  @spec kubectl!([String.t()], keyword()) :: String.t()
  def kubectl!(args, opts \\ []) do
    case kubectl(args, opts) do
      {output, 0} ->
        String.trim(output)

      {output, status} ->
        raise "kubectl #{Enum.join(args, " ")} exited #{status}:\n#{output}"
    end
  end

  @doc """
  Run a command inside a pod, and answer what it printed and what it exited with.

  This is how a negative claim is proven. `curl` from inside the pod to a host the
  egress policy denies fails *there*, which is a fact about the cluster; a test that
  looked at the policy object would be reading our own intentions back to us.
  """
  @spec exec(String.t(), String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def exec(namespace, pod, command) do
    kubectl(["exec", "-n", namespace, pod, "--" | command])
  end

  @doc "The first pod matching a selector, or nil. Names change; selectors do not."
  @spec pod(String.t(), String.t()) :: String.t() | nil
  def pod(namespace, selector) do
    case kubectl(["get", "pods", "-n", namespace, "-l", selector, "-o", "name"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.first()
        |> then(fn
          nil -> nil
          name -> String.replace_prefix(name, "pod/", "")
        end)

      _ ->
        nil
    end
  end

  @doc "Every pod matching a selector, ordered as the API server gave them."
  @spec pods(String.t(), String.t()) :: [String.t()]
  def pods(namespace, selector) do
    namespace
    |> jsonpath(selector, "{.items[*].metadata.name}")
    |> String.split(" ", trim: true)
  end

  defp jsonpath(namespace, selector, path) do
    case kubectl(["get", "pods", "-n", namespace, "-l", selector, "-o", "jsonpath=#{path}"]) do
      {output, 0} -> output
      _ -> ""
    end
  end

  @doc """
  Wait until a check answers true, or give up and say what it was waiting for.

  Polling rather than `kubectl wait`, because most of what this suite waits for is not a
  condition Kubernetes has a word for — a log continuing from a head hash, a bundle
  materialising, a prompt reaching a witness.
  """
  @spec eventually((-> boolean()), keyword()) :: :ok
  def eventually(check, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    every = Keyword.get(opts, :every, 2_000)
    what = Keyword.get(opts, :what, "a condition")

    deadline = System.monotonic_time(:millisecond) + timeout
    poll(check, deadline, every, what)
  end

  defp poll(check, deadline, every, what) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "e2e: gave up waiting for #{what}"

      true ->
        Process.sleep(every)
        poll(check, deadline, every, what)
    end
  end

  @doc """
  Open a local port onto something in the cluster, and close it when the test ends.

  The plane's control listener is deliberately not reachable through the ingress — a
  worker's NetworkPolicy allows exactly that port from exactly the plane's namespace, and
  that is the whole of why the enrolment token is the only authentication. So a test that
  wants to try enrolling has to do what nothing outside the cluster can, which is what
  this is: a hole opened on purpose, held for one test, and closed after it.
  """
  @spec port_forward(String.t(), String.t(), pos_integer()) :: pos_integer()
  def port_forward(namespace, target, remote_port) do
    local = free_port()

    port =
      Port.open({:spawn_executable, System.find_executable("kubectl")}, [
        :binary,
        :exit_status,
        :hide,
        args: [
          "--context",
          context(),
          "port-forward",
          "-n",
          namespace,
          target,
          "#{local}:#{remote_port}"
        ]
      ])

    ExUnit.Callbacks.on_exit(fn -> close_port(port) end)
    eventually(fn -> listening?(local) end, timeout: 30_000, what: "port-forward on #{local}")
    local
  end

  defp close_port(port) do
    with info when is_list(info) <- Port.info(port),
         {:os_pid, os_pid} <- List.keyfind(info, :os_pid, 0) do
      # Killing the child, not just closing the port: `kubectl port-forward` is a process
      # of its own and closing the pipe leaves it holding the local port, which the next
      # test then cannot have.
      kill(os_pid)
    end

    if Port.info(port), do: Port.close(port)
  catch
    _, _ -> :ok
  end

  defp kill(os_pid) do
    case :os.type() do
      {:win32, _} -> System.cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"], stderr_to_stdout: true)
      _ -> System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  defp listening?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  # Asked of the operating system rather than guessed, and then released: two tests
  # picking a number out of the same range is a flake nobody can reproduce.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @doc """
  A ServiceAccount token, minted by the real API server for a real audience.

  This is what makes the enrolment claims worth making. A test that handed the plane a
  string it made up would prove that the plane rejects strings; a token the cluster
  actually issued, for the right audience, to the wrong namespace, is the attack.
  """
  @spec token(String.t(), String.t(), String.t()) :: String.t()
  def token(namespace, service_account, audience) do
    kubectl!([
      "create",
      "token",
      service_account,
      "-n",
      namespace,
      "--audience",
      audience,
      "--duration",
      "10m"
    ])
  end

  @doc """
  Run helm against the same cluster, from the repository root.

  Upgrading the chart is a fault this suite injects, not a step it does on the side: a
  release re-applied under a running session is the thing being tested.
  """
  @spec helm([String.t()]) :: {String.t(), non_neg_integer()}
  def helm(args) do
    System.cmd("helm", ["--kube-context", context() | args],
      stderr_to_stdout: true,
      cd: repository_root()
    )
  end

  # The suite runs from `apps/troupe_operator`, and the chart is at the umbrella's root.
  defp repository_root, do: Path.expand("../../../../..", __DIR__)

  @doc """
  Put the secrets a worker namespace needs into it, the way `scripts/remote-up` does.

  Troupe creates no secrets, on purpose: the invariant is why compromising the plane gets
  an attacker requests that still pass policy rather than your Jira token. The consequence
  is that a *new* profile arrives with a namespace the operator made and nothing in it, and
  its workers cannot read a session's manifest from object storage — which surfaces as
  `sign_v4(nil, nil, ...)` several layers down and reads like a bug in the object store.

  In a real cluster this is External Secrets Operator. Here it is this function, and a
  test that creates a profile of its own has to call it for the same reason `remote-up`
  does for the shared one.
  """
  @spec secrets!(String.t()) :: :ok
  def secrets!(namespace) do
    secret!(namespace, "llm-credentials", [{"api-key", System.get_env("ITM_LLM_GW_KEY") || ""}])

    secret!(namespace, "troupe-object-store", [
      {"access-key-id", "troupe"},
      {"secret-access-key", "troupe-secret"}
    ])
  end

  # Created rather than applied. `remote-up` pipes a dry-run manifest into `apply` because
  # it is a shell script and a pipe is free there; from here it would need a file on disk
  # that both a Linux shell and a Windows kubectl agree about, which this repository has
  # already paid for once. A namespace the operator has just made has no secret in it, and
  # one that already does is not an error worth stopping for.
  defp secret!(namespace, name, literals) do
    args =
      ["create", "secret", "generic", name, "--namespace", namespace] ++
        Enum.map(literals, fn {key, value} -> "--from-literal=#{key}=#{value}" end)

    case kubectl(args) do
      {_output, 0} -> :ok
      {output, _status} -> if output =~ "AlreadyExists", do: :ok, else: raise(output)
    end
  end

  @doc """
  The same URL, reachable from wherever this suite is running.

  A worker's endpoint is the one the *outside* uses — `…workers.localtest.me:30080`,
  where 30080 is the port kind publishes on the host. Run from a container on Docker's
  `kind` network, as `scripts/e2e` does, the node is reached at its own address on port
  80 instead. On CI the suite runs on the host and there is nothing to rewrite.

  Only the port, and only when told: the host name is what the ingress routes on, so
  rewriting that would reach a different pod, or none at all.
  """
  @spec reachable(String.t()) :: String.t()
  def reachable(url) do
    case System.get_env("TROUPE_E2E_INGRESS_PORT") do
      nil -> url
      port -> URI.to_string(%{URI.parse(url) | port: String.to_integer(port)})
    end
  end

  @doc "The kubeconfig context this run is pinned to."
  @spec context() :: String.t()
  def context, do: System.get_env("TROUPE_E2E_CONTEXT") || "kind-troupe-dev"

  @doc """
  Whether the cluster is there at all, and looks like one `remote-up` built.

  Checked once, in `setup_all`, so that a cluster that is not up produces one clear
  sentence rather than eight tests failing in eight different ways.
  """
  @spec ready?() :: :ok | {:error, String.t()}
  def ready? do
    with {_, 0} <- kubectl(["cluster-info"]),
         {out, 0} <- kubectl(["get", "deployment", "-n", @namespace, "troupe-plane", "-o", "name"]),
         true <- String.contains?(out, "troupe-plane") do
      :ok
    else
      _ ->
        {:error,
         "no Troupe on context #{context()}. Bring one up with scripts/remote-up, " <>
           "or point TROUPE_E2E_CONTEXT at one."}
    end
  end
end
