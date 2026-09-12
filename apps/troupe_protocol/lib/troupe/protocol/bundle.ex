defmodule Troupe.Protocol.Bundle do
  @moduledoc """
  A config bundle's content: what a profile carries besides a model and file tools.

  The plane stores and publishes one; a worker fetches, verifies and materialises one;
  the admin panel edits one. All three need the same answers — is this document
  well-formed, what is its hash, what does it contain — so those answers live here,
  where every app can see them, rather than in any one of them.

  ## Schema 1

      {"schema": 1,
       "agents":      [{"name": "reviewer", "definition": "---\\nmode: primary\\n---\\nYou review…"}],
       "skills":      [{"name": "review-checklist", "description": "How we review…",
                        "files": {"SKILL.md": "…", "checklist.md": "…"}}],
       "mcp_servers": [{"name": "jira", "url": "https://mcp.jira.example/mcp",
                        "credential_ref": "JIRA_MCP_TOKEN", "header": "authorization",
                        "timeout_ms": 30000, "permission": "ask",
                        "tools": ["search_issues", "get_issue"]}]}

  A document with no `schema` is schema 0: the free-form map the first bundles were,
  of which only `mcp_servers` was ever read. It is accepted as exactly that, so a plane
  upgraded under a published bundle keeps working, and it is never written again.

  ## What is checked

  Names are `[a-z0-9-]`, unique per kind. An agent's definition must parse. A skill
  must have a `SKILL.md` whose frontmatter `name`, if present, is its own. An agent may
  only list skills the bundle has. An MCP URL must be `https://`, or `http://` to a
  cluster-internal `.svc` host, and a credential reference must look like the name of
  an environment variable rather than like a secret — a value in the plane's database
  is on the forbidden list, and the check is the difference between forbidding it and
  hoping. Sizes are bounded: the whole document by what the plane's router admits,
  one skill by what a system prompt could sensibly disclose.

  The egress check — is this host one the cluster policy lets a pod reach — is the
  caller's, because only the plane can read the policy. `validate/2` takes it as a
  function so the rule lives once.
  """

  alias Troupe.Protocol.{AgentDefinition, Canonical}

  @schema 1
  @max_document_bytes 4 * 1024 * 1024
  @max_skill_bytes 512 * 1024
  @default_header "authorization"
  @default_timeout_ms 30_000
  @permissions ~w(ask auto)

  @type agent :: %{name: String.t(), definition: String.t(), parsed: AgentDefinition.t()}
  @type skill :: %{name: String.t(), description: String.t(), files: %{String.t() => String.t()}}
  @type mcp_server :: %{
          name: String.t(),
          url: String.t(),
          credential_ref: String.t() | nil,
          header: String.t(),
          timeout_ms: pos_integer(),
          permission: :ask | :auto,
          tools: :all | [String.t()]
        }
  @type t :: %{
          schema: 0 | 1,
          agents: [agent()],
          skills: [skill()],
          mcp_servers: [mcp_server()]
        }

  @type option :: {:egress_allowed?, (String.t() -> boolean())} | {:builtin_agents, [String.t()]}

  @doc "The schema version this code writes."
  @spec schema() :: pos_integer()
  def schema, do: @schema

  @doc "The hash of a document: `sha256:` over its canonical JSON."
  @spec hash(map()) :: String.t()
  def hash(content) when is_map(content) do
    "sha256:" <>
      (:sha256
       |> :crypto.hash(Canonical.encode(content))
       |> Base.encode16(case: :lower))
  end

  @doc """
  Check a document and return its parsed form.

  Options: `:egress_allowed?`, a function of a hostname the caller answers from the
  cluster policy (absent means every host is allowed, which is right for a worker that
  is re-checking what the plane already admitted); `:builtin_agents`, the names an
  agent may not replace without `override: true`.
  """
  @spec validate(map(), [option()]) :: {:ok, t()} | {:error, [String.t()]}
  def validate(content, opts \\ [])

  def validate(content, opts) when is_map(content) do
    case Map.get(content, "schema", 0) do
      0 ->
        validate_legacy(content)

      @schema ->
        validate_v1(content, opts)

      other ->
        {:error,
         [
           "schema #{inspect(other)} is not one this plane knows; the current schema is #{@schema}"
         ]}
    end
  end

  def validate(_content, _opts), do: {:error, ["a bundle is a JSON object"]}

  @doc "Counts and names, for a listing that should not decode the whole document."
  @spec summary(t()) :: map()
  def summary(%{agents: agents, skills: skills, mcp_servers: servers} = bundle) do
    %{
      "schema" => bundle.schema,
      "agents" => Enum.map(agents, & &1.name),
      "skills" => Enum.map(skills, & &1.name),
      "mcp_servers" => Enum.map(servers, & &1.name)
    }
  end

  @doc """
  The MCP servers in the wire shape `Troupe.MCP.Server.from_config/1` reads.

  `permission` and `tools` ride along; the worker applies them after discovery.
  """
  @spec mcp_server_configs(t()) :: [map()]
  def mcp_server_configs(%{mcp_servers: servers}) do
    Enum.map(servers, fn server ->
      %{
        "name" => server.name,
        "url" => server.url,
        "credential_ref" => server.credential_ref,
        "header" => server.header,
        "timeout_ms" => server.timeout_ms,
        "permission" => Atom.to_string(server.permission),
        "tools" => if(server.tools == :all, do: "all", else: server.tools)
      }
    end)
  end

  @doc """
  Write a bundle's agents and skills under `dir`: `agents/<name>.md` and
  `skills/<name>/<file>`, plus `bundle.json` with the document itself.

  Written into a scratch directory beside `dir` and renamed into place, so a reader
  never sees half a bundle; a `dir` that already exists is left alone, because a
  bundle is immutable and the directory is named by its hash.
  """
  @spec materialize(t(), map(), Path.t()) :: :ok | {:error, term()}
  def materialize(%{} = bundle, content, dir) do
    if File.dir?(dir) do
      :ok
    else
      scratch = dir <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      try do
        File.mkdir_p!(Path.join(scratch, "agents"))
        File.mkdir_p!(Path.join(scratch, "skills"))

        Enum.each(bundle.agents, fn agent ->
          File.write!(Path.join([scratch, "agents", agent.name <> ".md"]), agent.definition)
        end)

        Enum.each(bundle.skills, fn skill ->
          skill_dir = Path.join([scratch, "skills", skill.name])
          File.mkdir_p!(skill_dir)

          Enum.each(skill.files, fn {relative, text} ->
            path = Path.join(skill_dir, relative)
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, text)
          end)
        end)

        File.write!(Path.join(scratch, "bundle.json"), Jason.encode!(content))
        File.mkdir_p!(Path.dirname(dir))

        case File.rename(scratch, dir) do
          :ok -> :ok
          # Somebody else finished first; theirs is the same bundle by construction.
          {:error, :eexist} -> :ok
          {:error, reason} -> {:error, reason}
        end
      rescue
        e in File.Error -> {:error, e.reason}
      after
        File.rm_rf(scratch)
      end
    end
  end

  @doc "The skill named, from a materialised directory: its `SKILL.md` body and its files."
  @spec read_skill(Path.t(), String.t()) ::
          {:ok, %{name: String.t(), body: String.t(), files: [String.t()]}} | {:error, :not_found}
  def read_skill(dir, name) do
    skill_dir = Path.join([dir, "skills", name])
    manifest = Path.join(skill_dir, "SKILL.md")

    with true <- AgentDefinition.valid_name?(name),
         {:ok, text} <- File.read(manifest) do
      {_frontmatter, body} = AgentDefinition.split_frontmatter(text)

      files =
        skill_dir
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, skill_dir))
        |> Enum.sort()

      {:ok, %{name: name, body: String.trim(body), files: files}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Name and description of every skill in a materialised directory, for a prompt."
  @spec list_skills(Path.t()) :: [%{name: String.t(), description: String.t()}]
  def list_skills(dir) do
    dir
    |> Path.join("skills/*/SKILL.md")
    |> Path.wildcard()
    |> Enum.map(fn manifest ->
      name = manifest |> Path.dirname() |> Path.basename()
      {frontmatter, _body} = manifest |> File.read!() |> AgentDefinition.split_frontmatter()

      description =
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, %{"description" => d}} when is_binary(d) -> d
          _ -> ""
        end

      %{name: name, description: description}
    end)
    |> Enum.sort_by(& &1.name)
  end

  # -- schema 0 ---------------------------------------------------------------

  defp validate_legacy(content) do
    servers = Map.get(content, "mcp_servers", [])

    with {:ok, servers} <- collect(servers, &legacy_server/1) do
      {:ok, %{schema: 0, agents: [], skills: [], mcp_servers: servers}}
    end
  end

  defp legacy_server(%{"name" => name, "url" => url} = raw)
       when is_binary(name) and is_binary(url) do
    {:ok,
     %{
       name: name,
       url: url,
       credential_ref: raw["credential_ref"] || raw["secret_ref"],
       header: raw["header"] || @default_header,
       timeout_ms: raw["timeout_ms"] || @default_timeout_ms,
       permission: :ask,
       tools: :all
     }}
  end

  defp legacy_server(other), do: {:error, "mcp server #{inspect(other)} needs a name and a url"}

  # -- schema 1 ---------------------------------------------------------------

  defp validate_v1(content, opts) do
    egress_allowed? = Keyword.get(opts, :egress_allowed?, fn _host -> true end)
    builtins = Keyword.get(opts, :builtin_agents, [])

    with :ok <- check_size(content),
         :ok <- only_known_keys(content),
         {:ok, skills} <- collect(Map.get(content, "skills", []), &skill/1),
         {:ok, agents} <- collect(Map.get(content, "agents", []), &agent(&1, skills, builtins)),
         {:ok, servers} <-
           collect(Map.get(content, "mcp_servers", []), &server(&1, egress_allowed?)),
         :ok <- unique(:agents, agents),
         :ok <- unique(:skills, skills),
         :ok <- unique(:mcp_servers, servers) do
      {:ok, %{schema: @schema, agents: agents, skills: skills, mcp_servers: servers}}
    end
  end

  defp check_size(content) do
    if byte_size(Jason.encode!(content)) > @max_document_bytes,
      do: {:error, ["the bundle is larger than #{@max_document_bytes} bytes"]},
      else: :ok
  end

  @known ~w(schema agents skills mcp_servers)
  defp only_known_keys(content) do
    case Map.keys(content) -- @known do
      [] -> :ok
      unknown -> {:error, ["unknown keys: #{Enum.join(unknown, ", ")}"]}
    end
  end

  defp collect(items, fun) when is_list(items) do
    {oks, errors} =
      items
      |> Enum.map(fun)
      |> Enum.split_with(&match?({:ok, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(oks, fn {:ok, v} -> v end)}
      _ -> {:error, Enum.flat_map(errors, fn {:error, e} -> List.wrap(e) end)}
    end
  end

  defp collect(other, _fun), do: {:error, ["expected a list, got #{inspect(other)}"]}

  defp unique(kind, items) do
    names = Enum.map(items, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> :ok
      dups -> {:error, ["#{kind}: duplicate names #{Enum.join(Enum.uniq(dups), ", ")}"]}
    end
  end

  defp agent(%{"name" => name, "definition" => text}, skills, builtins)
       when is_binary(name) and is_binary(text) do
    skill_names = Enum.map(skills, & &1.name)

    with true <-
           AgentDefinition.valid_name?(name) ||
             {:error, "agent #{inspect(name)}: not a valid name"},
         {:ok, parsed} <- parse_agent(name, text),
         :ok <- known_skills(name, parsed.skills, skill_names),
         :ok <- may_shadow(name, parsed.override, builtins) do
      {:ok, %{name: name, definition: text, parsed: parsed}}
    end
  end

  defp agent(other, _skills, _builtins),
    do: {:error, "agent #{inspect(other)} needs a name and a definition"}

  defp parse_agent(name, text) do
    case AgentDefinition.parse(name, text) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, "agent #{name}: #{inspect(reason)}"}
    end
  end

  defp known_skills(_name, :all, _skills), do: :ok

  defp known_skills(name, listed, skills) do
    case listed -- skills do
      [] ->
        :ok

      missing ->
        {:error,
         "agent #{name} lists skills the bundle does not have: #{Enum.join(missing, ", ")}"}
    end
  end

  defp may_shadow(name, override, builtins) do
    if name in builtins and not override,
      do: {:error, "agent #{name} replaces a built-in; say `override: true` if that is meant"},
      else: :ok
  end

  defp skill(%{"name" => name, "files" => files} = raw) when is_binary(name) and is_map(files) do
    with true <-
           AgentDefinition.valid_name?(name) ||
             {:error, "skill #{inspect(name)}: not a valid name"},
         :ok <- files_ok(name, files),
         {:ok, manifest} <- Map.fetch(files, "SKILL.md") |> manifest_present(name),
         :ok <- manifest_name(name, manifest),
         :ok <- skill_size(name, files) do
      {:ok, %{name: name, description: to_string(raw["description"] || ""), files: files}}
    end
  end

  defp skill(other), do: {:error, "skill #{inspect(other)} needs a name and files"}

  defp manifest_present(:error, name), do: {:error, "skill #{name} has no SKILL.md"}
  defp manifest_present({:ok, text}, _name) when is_binary(text), do: {:ok, text}
  defp manifest_present(_, name), do: {:error, "skill #{name}: SKILL.md is not text"}

  defp manifest_name(name, text) do
    {frontmatter, _} = AgentDefinition.split_frontmatter(text)

    case YamlElixir.read_from_string(frontmatter) do
      {:ok, %{"name" => other}} when other != name ->
        {:error, "skill #{name}: SKILL.md says its name is #{inspect(other)}"}

      {:error, reason} ->
        {:error, "skill #{name}: SKILL.md frontmatter: #{inspect(reason)}"}

      _ ->
        :ok
    end
  end

  defp files_ok(name, files) do
    bad =
      files
      |> Map.keys()
      |> Enum.reject(fn path ->
        is_binary(path) and path != "" and not String.starts_with?(path, "/") and
          not String.contains?(path, "\\") and
          not Enum.any?(Path.split(path), &(&1 == ".."))
      end)

    text = files |> Map.values() |> Enum.reject(&is_binary/1)

    cond do
      bad != [] -> {:error, "skill #{name}: file names must be relative: #{inspect(bad)}"}
      text != [] -> {:error, "skill #{name}: every file is text"}
      true -> :ok
    end
  end

  defp skill_size(name, files) do
    bytes = files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    if bytes > @max_skill_bytes,
      do:
        {:error,
         "skill #{name} is #{bytes} bytes; the most a skill may be is #{@max_skill_bytes}"},
      else: :ok
  end

  @env_name ~r/\A[A-Z][A-Z0-9_]{1,63}\z/

  defp server(%{"name" => name, "url" => url} = raw, egress_allowed?)
       when is_binary(name) and is_binary(url) do
    with true <-
           AgentDefinition.valid_name?(name) ||
             {:error, "mcp server #{inspect(name)}: not a valid name"},
         {:ok, host} <- url_ok(name, url),
         :ok <- egress_ok(name, host, egress_allowed?),
         {:ok, ref} <- credential_ref(name, raw["credential_ref"] || raw["secret_ref"]),
         {:ok, permission} <- permission(name, raw["permission"]),
         {:ok, tools} <- tools(name, raw["tools"]) do
      {:ok,
       %{
         name: name,
         url: url,
         credential_ref: ref,
         header: raw["header"] || @default_header,
         timeout_ms: positive(raw["timeout_ms"]) || @default_timeout_ms,
         permission: permission,
         tools: tools
       }}
    end
  end

  defp server(other, _), do: {:error, "mcp server #{inspect(other)} needs a name and a url"}

  defp url_ok(name, url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:ok, host}

      %URI{scheme: "http", host: host} when is_binary(host) ->
        if String.ends_with?(host, ".svc") or String.contains?(host, ".svc."),
          do: {:ok, host},
          else: {:error, "mcp server #{name}: #{url} is plain http to a host outside the cluster"}

      _ ->
        {:error, "mcp server #{name}: #{inspect(url)} is not an https URL"}
    end
  end

  defp egress_ok(name, host, allowed?) do
    if allowed?.(host),
      do: :ok,
      else:
        {:error, "mcp server #{name}: #{host} is not a host the cluster policy lets a pod reach"}
  end

  defp credential_ref(_name, nil), do: {:ok, nil}

  defp credential_ref(name, ref) when is_binary(ref) do
    if Regex.match?(@env_name, ref),
      do: {:ok, ref},
      else:
        {:error,
         "mcp server #{name}: credential_ref #{inspect(String.slice(ref, 0, 8))}… is not the name of an environment variable; a secret's value does not go in a bundle"}
  end

  defp credential_ref(name, _),
    do: {:error, "mcp server #{name}: credential_ref must be a string"}

  defp permission(_name, nil), do: {:ok, :ask}
  defp permission(_name, p) when p in @permissions, do: {:ok, String.to_existing_atom(p)}

  defp permission(name, p),
    do: {:error, "mcp server #{name}: permission #{inspect(p)} is not ask or auto"}

  defp tools(_name, nil), do: {:ok, :all}
  defp tools(_name, "all"), do: {:ok, :all}

  defp tools(name, list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list},
      else: {:error, "mcp server #{name}: tools is a list of names"}
  end

  defp tools(name, _), do: {:error, "mcp server #{name}: tools is a list of names or \"all\""}

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil
end
