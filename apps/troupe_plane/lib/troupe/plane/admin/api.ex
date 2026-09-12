defmodule Troupe.Plane.Admin.API do
  @moduledoc """
  The admin JSON-RPC methods, and nothing behind them.

  Every clause here is a rename: a method name to a `Troupe.Plane.Admin` function and its
  arguments. That is deliberate and is the point of the module — if a method needed logic
  of its own, the panel and the CLI would not be getting the same behaviour, and the
  parity this whole arrangement exists to guarantee would be a claim rather than a fact.

  `Troupe.Plane.AdminParityTest` enumerates `Admin` and asserts each function appears
  here and in `troupe admin`.
  """

  alias Troupe.Plane.Admin
  alias Troupe.Protocol.Error

  @methods %{
    "admin.overview" => {:overview, []},
    "admin.profiles.list" => {:profiles_list, []},
    "admin.profile.get" => {:profile_get, ["name"]},
    "admin.profile.put" => {:profile_put, ["profile"]},
    "admin.profile.preview" => {:preview, ["profile"]},
    "admin.profile.delete" => {:profile_delete, ["name"]},
    "admin.pod.drain" => {:pod_drain, ["worker_id"]},
    "admin.teams.list" => {:teams_list, []},
    "admin.team.enable" => {:team_enable, ["group", "attrs"]},
    "admin.team.update" => {:team_update, ["name", "attrs"]},
    "admin.team.grant" => {:team_grant, ["name", "profile", "attrs"]},
    "admin.team.revoke" => {:team_revoke, ["name", "profile"]},
    "admin.team.admin.add" => {:team_admin_add, ["name", "subject"]},
    "admin.team.admin.remove" => {:team_admin_remove, ["name", "subject"]},
    "admin.sessions.list" => {:sessions_list, ["filter"]},
    "admin.session.erase" => {:session_erase, ["session_id"]},
    "admin.bundles.list" => {:bundles_list, ["channel"]},
    "admin.bundle.get" => {:bundle_get, ["channel", "version"]},
    "admin.bundle.validate" => {:bundle_validate, ["content"]},
    "admin.bundle.publish" => {:bundle_publish, ["channel", "content"]},
    "admin.bundle.retire" => {:bundle_retire, ["channel", "version"]},
    "admin.mcp.check" => {:mcp_check, ["url"]},
    "admin.audit.list" => {:audit_list, ["filter"]},
    "admin.provisioning.mode" => {:provisioning_mode, []},
    "admin.principals.list" => {:principals_list, ["team"]},
    "admin.principal.create" => {:principal_create, ["team", "principal"]},
    "admin.principal.rotate" => {:principal_rotate, ["subject"]},
    "admin.principal.disable" => {:principal_disable, ["subject"]},
    "admin.triggers.list" => {:triggers_list, ["team"]},
    "admin.trigger.put" => {:trigger_put, ["trigger"]},
    "admin.trigger.delete" => {:trigger_delete, ["team", "name"]},
    "admin.trigger.run" => {:trigger_run, ["team", "name"]},
    "admin.runs.list" => {:runs_list, ["filter"]}
  }

  @doc "Every admin method, and the `Admin` function it renames."
  @spec methods() :: %{String.t() => {atom(), [String.t()]}}
  def methods, do: @methods

  @doc "Whether a method name is an admin one."
  @spec admin_method?(String.t()) :: boolean()
  def admin_method?(method), do: Map.has_key?(@methods, method)

  @doc "Dispatch one admin request."
  @spec call(String.t(), map(), Admin.actor()) :: {:ok, term()} | {:error, Error.t()}
  def call(method, params, actor) do
    case Map.fetch(@methods, method) do
      :error -> {:error, Error.new(:method_not_found, %{method: method})}
      {:ok, {function, argument_names}} -> invoke(function, argument_names, params, actor)
    end
  end

  defp invoke(function, argument_names, params, actor) do
    arguments = Enum.map(argument_names, &argument(&1, params))
    Kernel.apply(Admin, function, [actor | arguments])
  end

  # `filter` and `attrs` are the two shapes a method takes a bag of options in; the rest
  # are plain values. A keyword list for the former because that is what the context
  # takes, and a context that took maps would be awkward for the CLI. A `profile`, a
  # `principal` or a `trigger` is the whole params map when it is not nested, so a
  # client may send the object flat or under its name.
  defp argument("filter", params), do: options(params["filter"] || params)
  defp argument("attrs", params), do: params["attrs"] || %{}
  defp argument("profile", params), do: params["profile"] || params
  defp argument("principal", params), do: params["principal"] || params
  defp argument("trigger", params), do: params["trigger"] || params
  defp argument("content", params), do: params["content"] || %{}
  defp argument(name, params), do: params[name]

  @known_options ~w(limit actor kind subject_id profile state team channel) ++
                   ~w(trigger status origin needs_review)

  defp options(params) when is_map(params) do
    for {key, value} <- params, key in @known_options, do: {String.to_existing_atom(key), value}
  end

  defp options(_params), do: []
end
