# HavenChat

## Provider routing (Discover → Add API key)

The Discover panel's "Add API key" button maps a models.dev provider to one of
the app's internal adapters (`openai_compatible`, `anthropic`, `gemini_native`).
Routing is **evidence-based**: we only enable the button when we have positive
evidence the provider speaks the adapter's wire protocol.

### What models.dev gives us

Each provider in the `https://models.dev/catalog.json` catalog exposes:

| Field | What it is | Used for |
|---|---|---|
| `npm` | The AI SDK package that implements the provider (e.g. `@ai-sdk/anthropic`, `@ai-sdk/openai-compatible`). A routing hint, **not** a protocol declaration. | Picking the adapter family |
| `api` | The provider's REST base URL (e.g. `https://openrouter.ai/api/v1`). Only present on providers that publish one. | Prefilling `baseUrl` in the adapter config |
| `doc` | The provider's documentation URL. | Deriving a "get an API key" link (origin of the docs) |

The catalog does **not** have a field that says "this provider speaks OpenAI's
`/v1/chat/completions`." The `npm` field is the closest signal, and it's
reliable only for the explicitly-named packages below.

### How routing is decided

`resolveDefinitionFor` in `apps/lib/ui/pricing/quick_add_resolver.dart` returns
one of three outcomes:

- **Supported** — enabled button, opens the Quick Add flow prefilled with the
  adapter and base URL.
- **Uncertain** — disabled button with a tooltip. The `npm` package is
  recognised, but models.dev doesn't give us enough to route safely (typically
  because the provider has no `api` URL, so we can't prefill a base URL, and
  the `npm` field alone doesn't declare a wire protocol).
- **Unsupported** — no button. No adapter fits (e.g. labs scope, or an `npm`
  we don't recognise at all).

### Confirmed OpenAI-compatible (`npm` → `openai_compatible`)

These `npm` packages declare OpenAI compatibility in their name, so we route
them to the `openai_compatible` adapter — but only when the provider also
publishes an `api` URL (otherwise the button is disabled, since we can't
prefill the endpoint):

- `@ai-sdk/openai-compatible` (111 providers — the bulk)
- `@openrouter/ai-sdk-provider` (OpenRouter)
- `@ai-sdk/openai` (OpenAI, Vivgrid, Perplexity Agent)

### Known OpenAI-compatible fallback URLs

These providers speak OpenAI's `/v1/chat/completions` but don't publish an
`api` URL in models.dev — the base URL is baked into their dedicated SDK
package instead. We maintain the equivalent fallback here so the "Add API key"
button can be enabled for them. If a provider *does* publish an `api` URL in
the catalog, that takes precedence over the fallback.

| `npm` | Fallback base URL |
|---|---|
| `@ai-sdk/cerebras` | `https://api.cerebras.ai/v1` |
| `@ai-sdk/cohere` | `https://api.cohere.ai/compatibility/v1` |
| `@ai-sdk/deepinfra` | `https://api.deepinfra.com/v1/openai` |
| `@ai-sdk/groq` | `https://api.groq.com/openai/v1` |
| `@ai-sdk/mistral` | `https://api.mistral.ai/v1` |
| `@ai-sdk/perplexity` | `https://api.perplexity.ai/v1` |
| `@ai-sdk/togetherai` | `https://api.together.xyz/v1` |
| `@ai-sdk/xai` | `https://api.x.ai/v1` |

These URLs are the providers' public API roots (not internal details) and
mirror what the corresponding `@ai-sdk/*` packages hardcode. They're stable,
but if a provider changes their endpoint you'd need to update the map in
`quick_add_resolver.dart` (`_knownOpenAiCompatibleUrls`).

### Native adapters

- `@ai-sdk/anthropic` → `anthropic` adapter (Anthropic Messages API).
  The `npm` tag means "speaks the Anthropic Messages API shape" — it does
  **not** mean "is Anthropic". MiniMax, Kimi, FreeModel and others proxy
  Claude's API shape but need a key from their own platforms. The hardcoded
  `console.anthropic.com` key URL is kept only for the canonical `anthropic`
  provider; for all others the key link is derived from the provider's `doc`
  origin (e.g. MiniMax → `platform.minimax.io`, Kimi → `www.kimi.com`).
- `@ai-sdk/google` → `gemini_native` adapter (Gemini API). Same pattern: the
  hardcoded AI Studio key URL is kept only for the canonical `google`
  provider; any future Gemini-compatible proxy would get its key link derived
  from its `doc` origin.

### Uncertain (button disabled)

These `npm` packages are recognised, but their wire protocol or auth flow
can't be confirmed from the catalog alone, and we have no known base URL for
them. They need their own adapters (Bedrock, Azure, Vertex, …) — the button
is shown disabled with a tooltip pointing the user to the provider's docs:

- `@ai-sdk/amazon-bedrock` — Bedrock has its own request shape; no `api` URL.
- `@ai-sdk/azure` — Azure OpenAI is OpenAI-compatible, but Azure Cognitive
  Services is not; the `@ai-sdk/azure` package covers both, so it's ambiguous.
- `@ai-sdk/gateway` (Vercel) — gateway, protocol depends on the upstream
  provider.
- `@ai-sdk/google-vertex` — Vertex AI is a GCP product with project-based
  auth (API keys tied to a GCP project, or service accounts / OAuth), not the
  simple AI Studio API key flow the `gemini_native` adapter expects. No
  `gemini_vertex` adapter exists yet.
- `@ai-sdk/google-vertex/anthropic` — Anthropic-on-Vertex; not OpenAI-shaped,
  not the Gemini native API either.
- `@ai-sdk/vercel` (v0) — gateway, protocol depends on the upstream provider.
- `@aihubmix/ai-sdk-provider` — router, likely OpenAI-compatible, no `api` URL.
- `@jerome-benoit/sap-ai-core` — SAP AI Core, protocol unknown.
- `ai-gateway-provider` (Cloudflare AI Gateway) — gateway, protocol depends on
  the upstream provider.
- `gitlab-ai-provider` — GitLab AI, protocol unknown.
- `merge-gateway-ai-sdk-provider` — Merge Gateway, protocol unknown.
- `venice-ai-sdk-provider` — Venice AI, likely OpenAI-compatible, no `api` URL.

### Why not just assume OpenAI-compatible?

Three reasons:

1. **The catalog doesn't declare it.** The `npm` field tells you which SDK
   package implements the provider, not which wire protocol the provider speaks.
   `@ai-sdk/groq` doesn't say "OpenAI-compatible" — it says "use the Groq SDK."
2. **We'd need a base URL we don't have.** Most of these providers don't
   publish an `api` URL in the catalog, so even if we knew the protocol, we
   couldn't prefill the endpoint. Hardcoding base URLs would mean maintaining
   a list the catalog doesn't.
3. **Silent breakage is worse than a disabled button.** If we guess wrong, the
   user gets an adapter that produces runtime errors with no clear cause. A
   disabled button with a tooltip is honest and recoverable.

When models.dev adds a `protocol` or `wire_format` field (or starts publishing
`api` URLs for these providers), we can enable them.

