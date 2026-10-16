# Configuration cookbook

Complete files, one for each thing people set up most, each with what its lines do. Copy
one, change the names that are yours, and `troupe config` shows what is in effect.

Every file here is loaded by a test (`apps/troupe_core/test/troupe/config/cookbook_test.exs`)
through the reader Troupe itself uses for it, the strict one for `config.yaml`, which
refuses a wrong type and warns on a key it does not know: a recipe that stopped loading
would fail the build, not you.

Where each file goes is on one page, [Where your files are](files.md); every key is in
[the key reference](../configuration.md#every-key).

| Recipe | The file |
|---|---|
| [Anthropic](providers.md#anthropic), the smallest useful file | `config.yaml` |
| [OpenAI](providers.md#openai) | `config.yaml` |
| [A gateway, such as LiteLLM](providers.md#a-gateway-such-as-litellm) | `config.yaml` |
| [Ollama, on your own machine](providers.md#ollama-on-your-own-machine) | `config.yaml` |
| [Azure OpenAI](providers.md#azure-openai) | `config.yaml` |
| [OpenRouter](providers.md#openrouter) | `config.yaml` |
| [Gemini](providers.md#gemini) | `config.yaml` |
| [A team's project file](team-and-personal.md#a-teams-project-file) | `.troupe/config.yaml` |
| [A personal config.local.yaml](team-and-personal.md#a-personal-configlocalyaml) | `.troupe/config.local.yaml` |
| [MCP servers](mcp-agents-skills.md#mcp-servers) | `mcp.json` |
| [A custom agent](mcp-agents-skills.md#a-custom-agent) | `agents/<name>.md` |
| [A skill](mcp-agents-skills.md#a-skill) | `skills/<name>/SKILL.md` |
| [An unattended session](unattended.md), its budgets and approvals | `config.yaml` |
| [Per-tool permission rules](permissions.md) | `config.yaml` |

Not here: Bedrock and Vertex, which are not provider types (each signs its requests with
its own cloud's credentials; a gateway in front of either is the type of the API the
gateway speaks).
