defmodule Troupe.Config.ModelSettings do
  @moduledoc """
  The provider, key and models a person picks for their own machine: read, tried and
  written, for a settings screen.

  This is what the daemon's `config.get`, `config.models` and `config.set` stand on, and
  it edits exactly one file — the user's `config.yaml` in `Troupe.Paths.config_dir/0` —
  because that is the file every session on the machine starts from, and because the
  process that reads it is the one that resolved its path. A client never names a
  path: a desktop app and the daemon it talks to could disagree about `%APPDATA%`, and
  the daemon is the one whose opinion decides what a session sees.

  What the screen shows is the file, not the effective configuration: that is what
  saving changes. Everything that would beat the file anyway — a project's
  `.troupe/config.yaml`, a `TROUPE_*` variable, the opencode fallback — is reported
  beside it as an override, so nobody saves a model and wonders why nothing changed.

  The key goes in and never comes out. `describe/1` says whether one is set and where
  it comes from; the value itself is only ever sent to the provider it was typed for.
  """

  alias Troupe.Config
  alias Troupe.Config.{OpenCode, Yaml}
  alias Troupe.LLM.Catalog
  alias Troupe.LLM.Catalog.Store

  @providers ~w(anthropic openai)
  @auths ~w(api_key bearer)
  @roles ~w(default cheap expensive)

  # Each role is spelled two ways in a config file — the `models:` block and a flat key —
  # and `cheap` has a third. Setting a role removes the other spellings, because which of
  # two disagreeing keys wins would otherwise depend on map order.
  @spellings %{
    "default" => {["default"], ["model"]},
    "cheap" => {["cheap", "small"], ["small_model"]},
    "expensive" => {["expensive"], ["expensive_model"]}
  }

  @env_overrides [
    {"TROUPE_PROVIDER", "provider"},
    {"TROUPE_BASE_URL", "base_url"},
    {"TROUPE_API_KEY", "api_key"},
    {"TROUPE_AUTH_TOKEN", "api_key"},
    {"TROUPE_AUTH", "auth"},
    {"TROUPE_MODEL", "models.default"},
    {"TROUPE_SMALL_MODEL", "models.cheap"},
    {"TROUPE_EXPENSIVE_MODEL", "models.expensive"}
  ]

  @managed ~w(provider base_url auth api_key auth_token model small_model expensive_model models)

  @type description :: %{String.t() => term()}

  @doc """
  The user's file as a settings screen shows it, and what overrides it.

  With a workspace, a project `.troupe/config.yaml` there is reported as an override;
  without one only the machine-wide sources are.
  """
  @spec describe(Path.t() | nil) :: description()
  def describe(workspace \\ nil) do
    path = Config.user_path()
    file = read(path)
    models = file_models(file)

    %{
      "config_dir" => Path.dirname(path),
      "path" => path,
      "exists" => File.regular?(path),
      "provider" => string(file["provider"]) || "anthropic",
      "base_url" => string(file["base_url"]),
      "auth" => file_auth(file),
      "api_key_set" => key_source(file) != nil,
      "api_key_source" => key_source(file),
      "models" => models,
      "overrides" => overrides(file, workspace)
    }
  end

  @doc """
  Asks a provider what models it serves, for settings that may not be saved yet.

  Every field is optional and falls back to the file, so a screen can try a new key
  against the saved provider or a new provider with the saved key. Nothing is written,
  not even the model cache: a key being tried out has not been accepted yet.
  """
  @spec discover(map()) :: {:ok, map()} | {:error, String.t()}
  def discover(params) when is_map(params) do
    file = read(Config.user_path())

    with {:ok, provider} <- provider(Map.get(params, "provider", file["provider"] || "anthropic")),
         {:ok, auth} <- auth(Map.get(params, "auth", file_auth(file))) do
      key = present(params["api_key"]) || saved_key(file)

      config = %Config{
        provider: provider,
        base_url: present(Map.get(params, "base_url", file["base_url"])),
        api_key: key,
        auth: String.to_existing_atom(auth),
        providers: %{}
      }

      if key do
        {entries, failures} = Store.discover(config)

        {:ok,
         %{
           "models" => entries |> Enum.sort_by(& &1.id) |> Enum.map(&model_json/1),
           "failures" =>
             Enum.map(failures, fn {name, reason} -> failure(provider, name, reason) end)
         }}
      else
        {:ok,
         %{"models" => [], "failures" => [%{"provider" => provider, "reason" => "no API key"}]}}
      end
    end
  end

  @doc """
  Writes the choices into the user's file and answers what `describe/1` now says.

  Only the keys this screen owns are touched; everything else in the file is kept. The
  file is rewritten, so comments do not survive: the previous file is kept beside it as
  `config.yaml.previous`, the first thing to reach for when a hand-written file lost
  something it cared about.

    * `api_key` absent keeps the saved key; `""` removes it.
    * `base_url` `nil` or `""` removes it, and with it the provider's own default applies.
    * a model role set to `nil` or `""` removes it.
  """
  @spec write(map(), Path.t() | nil) :: {:ok, description()} | {:error, String.t()}
  def write(params, workspace \\ nil) when is_map(params) do
    path = Config.user_path()

    with {:ok, raw} <- parse_existing(path),
         {:ok, provider} <- provider(Map.get(params, "provider", raw["provider"] || "anthropic")),
         {:ok, auth} <- optional_auth(Map.get(params, "auth")),
         {:ok, models} <- models(Map.get(params, "models", %{})) do
      updated =
        raw
        |> Map.put("provider", provider)
        |> put_base_url(params)
        |> put_auth(auth)
        |> put_key(params)
        |> put_models(models)

      with :ok <- save(path, updated) do
        {:ok, describe(workspace)}
      end
    end
  end

  @doc """
  Copies opencode's providers into the user's file, so the machine keeps what it set up
  in opencode without reading opencode's config at every session.

  Each provider lands in `providers:` as opencode declares it (type, base URL, auth style
  and models) with its key as it is written there. An `{env:VAR}` reference stays a
  reference; a literal key, or one from opencode's `auth.json`, is copied, which is what
  a person asking for the copy asked for. A provider the file already names is left as it
  is, and opencode's default model becomes `models.default` only when the file has none.

  The answer is `describe/1`'s plus `"imported"`: `"from"` (opencode's config),
  `"providers"` (copied), `"kept"` (already in the file) and `"default"` (set, or nil).
  Nothing is written when there is nothing to copy.
  """
  @spec import_opencode(Path.t() | nil) :: {:ok, description()} | {:error, String.t()}
  def import_opencode(workspace \\ nil) do
    path = Config.user_path()
    providers = OpenCode.providers()

    with :ok <- any_providers(providers),
         {:ok, raw} <- parse_existing(path) do
      existing = file_providers(raw)

      {copied, kept} =
        providers
        |> Map.keys()
        |> Enum.sort()
        |> Enum.split_with(&(not Map.has_key?(existing, &1)))

      default = if file_models(raw)["default"], do: nil, else: OpenCode.default_model()

      imported = %{
        "from" => OpenCode.config_path(),
        "providers" => copied,
        "kept" => kept,
        "default" => default
      }

      updated =
        raw
        |> Map.put(
          "providers",
          Map.merge(existing, Map.new(copied, &{&1, provider_yaml(providers[&1])}))
        )
        |> put_models(if default, do: %{"default" => default}, else: %{})

      with :ok <- save_unless(copied == [] and default == nil, path, updated) do
        {:ok, Map.put(describe(workspace), "imported", imported)}
      end
    end
  end

  # An import that finds everything already there leaves the file, and its `.previous`,
  # alone.
  defp save_unless(true = _nothing_new, _path, _updated), do: :ok
  defp save_unless(false, path, updated), do: save(path, updated)

  defp any_providers(providers) when map_size(providers) == 0,
    do: {:error, "there are no providers in #{OpenCode.config_path()} to copy"}

  defp any_providers(_providers), do: :ok

  # One opencode provider as `providers:` spells it, so it loads back to the same spec.
  defp provider_yaml(provider) do
    drop_empty(%{
      "type" => Atom.to_string(provider.type),
      "base_url" => provider.base_url,
      "api_key" => provider.api_key,
      "auth" => if(provider.auth == :bearer, do: "bearer"),
      "models" =>
        Map.new(provider.models, fn {name, model} -> {name, model_yaml(name, model)} end)
    })
  end

  defp model_yaml(name, model) do
    drop_empty(%{
      "id" => if(model.id != name, do: model.id),
      "context" => model.context,
      "max_output" => model.max_output,
      "reasoning_effort" => model.reasoning_effort
    })
  end

  defp drop_empty(map),
    do:
      map |> Enum.reject(fn {_key, value} -> value in [nil, ""] or value == %{} end) |> Map.new()

  # A file that is there but does not parse is somebody's work in progress, not an
  # empty config: rewriting it from `%{}` would throw it away.
  defp parse_existing(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "could not read #{path}: #{:file.format_error(reason)}"}

      {:ok, contents} ->
        case YamlElixir.read_from_string(contents) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, nil} -> {:ok, %{}}
          _ -> {:error, "#{path} is not a YAML map; fix it or move it aside, then save again"}
        end
    end
  end

  # -- reading ------------------------------------------------------------------

  # Interpolated, for what a session would see: whether a `{env:VAR}` key is set.
  defp read(path), do: Config.interpolate(read_raw(path))

  # As written, for rewriting: an `{env:VAR}` reference must stay a reference.
  defp read_raw(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, map} when is_map(map) <- YamlElixir.read_from_string(contents) do
      map
    else
      _ -> %{}
    end
  end

  defp file_models(file) do
    block = if is_map(file["models"]), do: file["models"], else: %{}

    Map.new(@roles, fn role ->
      {names, [flat]} = @spellings[role]
      value = Enum.find_value(names, &string(block[&1])) || string(file[flat])
      {role, value}
    end)
  end

  defp file_auth(file) do
    cond do
      present(file["auth_token"]) -> "bearer"
      file["auth"] in @auths -> file["auth"]
      true -> "api_key"
    end
  end

  defp saved_key(file) do
    present(System.get_env("TROUPE_AUTH_TOKEN")) || present(System.get_env("TROUPE_API_KEY")) ||
      present(file["auth_token"]) || present(file["api_key"])
  end

  defp key_source(file) do
    cond do
      present(System.get_env("TROUPE_API_KEY")) || present(System.get_env("TROUPE_AUTH_TOKEN")) ->
        "env"

      present(file["api_key"]) || present(file["auth_token"]) || keyed_provider?(file) ->
        "file"

      OpenCode.providers() != %{} ->
        "opencode"

      true ->
        nil
    end
  end

  defp file_providers(file), do: if(is_map(file["providers"]), do: file["providers"], else: %{})

  defp keyed_provider?(file) do
    Enum.any?(file_providers(file), fn {_name, provider} ->
      is_map(provider) and
        (present(provider["api_key"]) || present(provider["auth_token"])) != nil
    end)
  end

  defp overrides(file, workspace) do
    project(workspace) ++ env() ++ opencode(file)
  end

  defp project(nil), do: []

  defp project(workspace) do
    path = Path.join(Troupe.Paths.project_dir(workspace), "config.yaml")
    keys = path |> read_raw() |> Map.keys() |> Enum.filter(&(&1 in @managed)) |> Enum.sort()

    if keys == [],
      do: [],
      else: [%{"source" => "project", "detail" => "#{path} sets #{Enum.join(keys, ", ")}"}]
  end

  defp env do
    for {var, setting} <- @env_overrides, present(System.get_env(var)) do
      %{"source" => "env", "detail" => "#{var} is set and overrides #{setting}"}
    end
  end

  # opencode is only consulted when the session has no key of its own, and a provider the
  # file names (one copied from opencode, say) shadows opencode's of the same name.
  defp opencode(file) do
    unshadowed = Map.keys(OpenCode.providers()) -- Map.keys(file_providers(file))

    if saved_key(file) == nil and unshadowed != [] do
      [
        %{
          "source" => "opencode",
          "detail" => "no key is saved, so the providers in #{OpenCode.config_path()} are used"
        }
      ]
    else
      []
    end
  end

  # -- writing ------------------------------------------------------------------

  defp put_base_url(raw, %{"base_url" => url}) do
    case present(url) do
      nil -> Map.delete(raw, "base_url")
      url -> Map.put(raw, "base_url", url)
    end
  end

  defp put_base_url(raw, _params), do: raw

  defp put_auth(raw, nil), do: raw
  defp put_auth(raw, auth), do: Map.put(raw, "auth", auth)

  # A new key replaces both spellings. `auth_token` implied bearer, so a file that had
  # one keeps bearer unless the screen said otherwise.
  defp put_key(raw, %{"api_key" => ""}), do: Map.drop(raw, ["api_key", "auth_token"])

  defp put_key(raw, %{"api_key" => key}) when is_binary(key) do
    raw =
      if Map.has_key?(raw, "auth_token") and not Map.has_key?(raw, "auth"),
        do: Map.put(raw, "auth", "bearer"),
        else: raw

    raw |> Map.delete("auth_token") |> Map.put("api_key", key)
  end

  defp put_key(raw, _params), do: raw

  defp put_models(raw, models) when map_size(models) == 0, do: raw

  defp put_models(raw, models) do
    block = if is_map(raw["models"]), do: raw["models"], else: %{}

    {block, raw} =
      Enum.reduce(models, {block, raw}, fn {role, value}, {block, raw} ->
        {names, flats} = @spellings[role]
        block = Map.drop(block, names)
        raw = Map.drop(raw, flats)
        block = if value, do: Map.put(block, role, value), else: block
        {block, raw}
      end)

    if block == %{}, do: Map.delete(raw, "models"), else: Map.put(raw, "models", block)
  end

  # Written beside the target and renamed over it, so a crash mid-write leaves the old
  # file rather than half a new one. The key is in there, so on Unix only the user may
  # read it; on Windows the file lives in the user's own profile.
  defp save(path, updated) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"

    # The copy may hold a key too, so it is locked down like the file itself.
    if File.regular?(path) and File.cp(path, path <> ".previous") == :ok,
      do: restrict(path <> ".previous")

    with :ok <- File.write(tmp, header() <> Yaml.encode(updated)),
         :ok <- restrict(tmp),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp header do
    "# Written by troupe's model settings. Comments are not kept; the file before the\n" <>
      "# last save is config.yaml.previous.\n"
  end

  defp restrict(path) do
    case :os.type() do
      {:unix, _} -> File.chmod(path, 0o600)
      _ -> :ok
    end
  end

  # -- validation ---------------------------------------------------------------

  defp provider(value) when value in @providers, do: {:ok, value}

  defp provider(value),
    do: {:error, "provider must be one of #{Enum.join(@providers, ", ")}, not #{inspect(value)}"}

  defp auth(value) when value in @auths, do: {:ok, value}

  defp auth(value),
    do: {:error, "auth must be one of #{Enum.join(@auths, ", ")}, not #{inspect(value)}"}

  defp optional_auth(nil), do: {:ok, nil}
  defp optional_auth(value), do: auth(value)

  defp models(models) when is_map(models) do
    Enum.reduce_while(models, {:ok, %{}}, fn
      {role, value}, {:ok, acc} when role in @roles and (is_nil(value) or is_binary(value)) ->
        {:cont, {:ok, Map.put(acc, role, present(value))}}

      {role, _value}, _acc when role in @roles ->
        {:halt, {:error, "models.#{role} must be a model id or null"}}

      {role, _value}, _acc ->
        {:halt,
         {:error, "unknown model role #{inspect(role)}; the roles are #{Enum.join(@roles, ", ")}"}}
    end)
  end

  defp models(_other), do: {:error, "models must be an object of role to model id"}

  # -- shapes -------------------------------------------------------------------

  defp model_json(%Catalog{} = e) do
    %{
      "id" => e.id,
      "context" => e.context,
      "max_output" => e.max_output,
      "input" => per_million(e.input),
      "output" => per_million(e.output)
    }
  end

  # The catalog prices per token; people compare prices per million.
  defp per_million(nil), do: nil
  defp per_million(per_token), do: Float.round(per_token * 1_000_000, 4)

  defp failure(provider, name, reason) do
    %{
      "provider" => if(name in [nil, "(session)"], do: provider, else: name),
      "reason" => reason(reason)
    }
  end

  defp reason({:http, 401}), do: "401 unauthorized: the key was refused"
  defp reason({:http, 403}), do: "403 forbidden: the key may not list models"
  defp reason({:http, 404}), do: "404: no model listing at that URL; check the base URL"
  defp reason({:http, status}), do: "HTTP #{status}"
  defp reason(:no_base_url), do: "an OpenAI-compatible provider needs a base URL"
  defp reason(other), do: inspect(other)

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
