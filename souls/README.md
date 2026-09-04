# MCU Roster — Desktop "New Agent" reference card

Five bots. For each: create via **Desktop → New Agent**, paste the Title and
Description below, then open **Advanced** to paste the SOUL.md and pin the model.

SOUL.md files live beside this card in `/home/filip/hermes-stack/souls/`.

**Why Desktop and not `hermes profile create`:** the CLI does not write
`ui_meta['hermes-bots']` into `profile.yaml`. Without that marker the profile is
invisible to the Bots roster and `message_agent` never appears — which breaks
the entire Fury → Stark → Parker delegation loop. (`coulson` on the native
install is the proof case: CLI-created, no marker.)

**Title and Description are load-bearing**, not decoration:
`tools/bot_mode_probe.py:126-147` builds each bot's view of its teammates from
exactly these two fields. A vague description means Fury does not know who to
delegate to.

---

| # | Name | Title | Model | SOUL file |
|---|---|---|---|---|
| 1 | `nick-fury` | Strategic Manager & Delegator | `claude-sonnet-5` | `nick-fury.SOUL.md` |
| 2 | `phil-coulson` | Executive Assistant & iMessage Comms | `claude-opus-5` | `phil-coulson.SOUL.md` |
| 3 | `tony-stark` | Lead Systems Architect | `claude-fable-5` | `tony-stark.SOUL.md` |
| 4 | `daisy-johnson` | Security & Offensive Operations | `Qwen3.8-27B` (bamse) | `daisy-johnson.SOUL.md` |
| 5 | `peter-parker` | Lead Developer & Code Executor | `claude-sonnet-5` | `peter-parker.SOUL.md` |

---

## Descriptions (paste verbatim)

**nick-fury**
> Decomposes project goals into workstreams and assigns them across the team.
> Delegates architecture to Stark, implementation to Parker, security audits to
> Daisy, and scheduling/briefings to Coulson. Verifies outcomes and reports
> consolidated status.

**phil-coulson**
> Daily executive assistant and the iMessage gateway. Handles scheduling, task
> tracking, reminders, and morning/evening briefings. Reachable from Filip's
> iPhone via Photon; routes urgent technical requests to Fury or Stark.

**tony-stark**
> Lead systems architect. Turns goals into production-ready architectural specs,
> module boundaries, database schemas, and API interfaces. Reviews Parker's
> implementations for architectural integrity. Plans and reviews; does not write
> boilerplate.

**daisy-johnson**
> Security specialist. Audits codebases for vulnerabilities, hardcoded secrets,
> injection risks, and flawed access control. Runs diagnostics and local security
> tests, and hands remediation patches to Parker and Stark. Runs on the
> self-hosted Qwen endpoint so audit findings stay on Filip's infrastructure.

**peter-parker**
> Lead developer. Implements from Stark's specs: clones repos into
> /workspace/projects/, writes feature code and tests, runs pytest/npm test, and
> reports real output including failures. Returns PR summaries to Stark and Fury.

---

## Model pins (Advanced → model)

Four run on Anthropic; `daisy-johnson` runs on the self-hosted endpoint.

```yaml
# nick-fury, peter-parker
model:
  provider: anthropic
  default: claude-sonnet-5

# tony-stark
model:
  provider: anthropic
  default: claude-fable-5

# phil-coulson
model:
  provider: anthropic
  default: claude-opus-5
```

`daisy-johnson` needs the full provider block (shape copied from the working
native `daisy` profile — known-good, not invented):

```yaml
model:
  provider: bamse
  default: Qwen3.8-27B
  base_url: https://api.bamse.cloud/v1
  key_env: HERMES_CUSTOM_BAMSE_API_KEY
providers:
  bamse:
    name: AI Bamse
    base_url: https://api.bamse.cloud/v1
    model: Qwen3.8-27B
    discover_models: true
    models:
      Qwen3.8-27B: {}
    key_env: HERMES_CUSTOM_BAMSE_API_KEY
```

---

## After creating all five

1. **Authenticate.** The container home is fresh — no Anthropic credential
   exists yet. Per profile (daisy-johnson excepted, it uses the bamse key
   already in the stack `.env`):
   ```bash
   docker exec -it hermes_mcu_core bash
   hermes -p nick-fury auth add anthropic --type oauth --no-browser
   ```
   `-it` is required: the flow calls `input()` for the pasted code. The redirect
   is Anthropic's hosted callback, so no browser is needed inside the container.

2. **Verify the bot markers — five hits expected:**
   ```bash
   grep -l hermes-bots /home/filip/hermes-stack/hermes-home/profiles/*/profile.yaml | wc -l
   ```
   Fewer than five means a profile was created without the marker; it will not
   appear in the roster.

3. **Port hygiene.** All five default `platforms.api_server` to 8642 — five
   profiles, one port, four failures (exit 78/CONFIG). Either disable it where
   unneeded (cleanest; only `hermes peer` requires it) or assign 8651–8655.

4. **Delegation smoke test** from a conversation titled exactly `Bot Chat`:
   ask Fury to delegate a trivial task to Parker and confirm the reply returns.
