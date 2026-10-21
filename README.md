# Taskweave

**English** | [한국어](README.ko.md)

Taskweave is a workflow plugin for Codex and Claude Code. It helps you review what the AI intends to change before it edits your files, then follow the work through implementation, verification, and feedback.

For code and configuration changes—even small ones—the AI is instructed to show the current and proposed code and explain the verification method, then wait for your approval. Small tasks normally stay in the conversation. A Workplan is used when the change is complex, your project requires a record, or you ask for one.

This repository is a **GitHub-hosted plugin marketplace**. Add its address once, then install Taskweave through your host. It is not an entry in the default OpenAI or Anthropic directory. No separate Taskweave server or ZIP download is needed; its MCP process runs locally.

## What Taskweave helps you do

- Review a concrete change instead of approving a vague implementation summary.
- Connect a task to the relevant project rules and sources without reading every document for every request.
- Continue feedback from the current implementation and record, rather than restarting the investigation.
- Separate compilation, behavior tests, visual checks, and unverified work in the result.

Code work, research, summaries, and scripts share a common process, but not the same evidence. A text summary is checked against its source; an app change needs the relevant code or UI checks. Taskweave does not turn every writing request into a software project.

These are instructions for the AI, not a guarantee that a model will always follow them. Taskweave does not replace human review or the host's permissions.

## Try it: requests and expected responses

The following are illustrative examples, not results from a real project. Select a Taskweave skill explicitly if you want to make sure that workflow is used. In Codex, use `$taskweave:<skill>`; in Claude Code, use `/taskweave:<skill>`.

### A small code fix

Request with `code-change`:

> This label formatter crashes when the value is missing. Show me the code change and the checks before editing.

The AI should inspect the relevant file and propose something concrete, for example:

```javascript
// Before
return value.trim();

// Proposed
return value?.trim() ?? "";
```

It should explain why the change fits your actual code and propose checks for a normal value, an empty string, and a missing value. It must then wait. After you approve, it edits the agreed scope and reports what it actually checked. A new Markdown document is not required by default.

### A feature that affects several parts of an app

Request with `feature-plan`:

> Plan how to connect the home date picker to the existing date-selection flow. Show the affected files, representative code, and the tests. Do not implement it yet.

The AI should read the relevant project guidance, current implementation, and source material. It writes a Workplan explaining the current behavior, proposed behavior, important code changes, exclusions, and verification plan. If a product decision or source is missing, it asks a specific question instead of guessing.

After you approve that plan, `feature-apply` implements it. For UI work, the design-system planning and implementation skills add the relevant component, token, and visual checks to the same task; they do not create an unrelated second project.

### A bug investigation and follow-up

Request with `bugfix-plan`:

> Investigate why submitting this form sends two requests. Explain the cause, the proposed code, and a regression check. Do not edit yet.

The AI should distinguish observed facts from hypotheses, identify the affected code, and propose a fix and a check that would detect the bug. It waits for approval before `bugfix-apply` edits the code.

If you later say, “The error path still sends twice,” `apply-workplan-feedback` continues from the current implementation. Work already covered by the approved proposal can continue without repeating the first approval. If the feedback introduces additional code or verification outside that proposal, the AI shows that addition and asks for approval.

### A writing task

> Summarize these meeting notes. Preserve decisions, action owners, and unresolved questions. Do not create a file.

The AI uses the supplied notes and the writing guidance, then returns a summary in the conversation. It does not require Git registration, app tests, code coverage, or a Workplan. It should not invent missing facts. There is no separate childcare-log or script-writing skill in the current bundle; unfamiliar writing tasks use the common guidance and the material you provide.

## Install and set up

### Requirements

Have Node.js 22 or newer, Ruby, Git, and the CLI for the host you intend to use. Sign in to that host normally. The plugin includes its MCP dependencies, so a separate `npm install` is not needed.

Actual remote installation and MCP startup have been checked on macOS. Windows and Linux host installation have not been verified.

### Codex

```sh
codex plugin marketplace add https://github.com/chando-park/taskweave.git
codex plugin add taskweave@taskweave-marketplace
```

Open a new conversation and request `$taskweave:setup`. If typing the name does not select a skill in your client, search for Taskweave in its skill selector.

### Claude Code

```sh
claude plugin marketplace add https://github.com/chando-park/taskweave.git --scope user
claude plugin install taskweave@taskweave-marketplace --scope user
```

Open a new conversation and request `/taskweave:setup`.

### What setup needs to know

Setup is optional for a plain conversation task. If you want project and record management, be ready to provide:

1. The folder containing your projects. Do not assume everyone uses the same folder layout.
2. The specific project you intend to work on. Discovery results need confirmation; a Git remote alone is not the task.
3. Where to keep work records, or the location of records you already have.
4. Which existing integrations to reuse and which missing ones you want to connect.

For example:

> My projects are in `/example/projects`. Use `example-app` for this task. My existing work records are in `/example/work-records/example-app`; keep them there. Reuse the Figma connection and do not create Jira tickets unless the project policy requires them.

Those paths are examples. The setup skill can guide you through the management CLI when available; otherwise it asks for the needed choices and reports what has not been saved. It must not claim that registration, authentication, or a read operation succeeded without confirmation.

Installing a plugin does **not** automatically replace your global `AGENTS.md` or `CLAUDE.md`. Use its named skills first. Making Taskweave the default for all conversations is a separate instruction-linking step that must preserve your existing guidance.

## How a task moves through the system

```text
Your request + current project
          |
          v
AI selects a Taskweave skill
          |
          v
Skill -> relevant shared rules -> project guidance and task sources
          |
          v
AI presents code changes and verification -> you approve
          |
          v
Host tools edit files and run the relevant checks
          |
          v
AI explains the actual changes, results, and remaining gaps
          |
          +-> feedback: continue the current work
          `-> acceptance: close a Workplan only when you request it
```

A skill is the procedure the AI reads. References contain the more detailed rules it needs for a particular task. The host supplies the actual editor, terminal, and service tools. MCP provides access to scoped material and records; it does not implement the feature itself.

A build passing does not prove that a UI matches Figma. When visual conformance is required, the AI must compare the actual render with an independent design source at a matching state and boundary. Recording the current render as its own answer is not conformance verification.

Approval to implement does not also authorize commit, push, MR/PR creation, external publication, Jira closure, or knowledge publication. Those actions need their own applicable permission. Ordinary conversation results do not require a formal closing ceremony.

## Skills: choose by the work you need

The bundle contains 14 personal workflow skills plus `setup`. The names below work with the Codex `$taskweave:` or Claude `/taskweave:` prefix.

| Skill | When to use it | What it does |
| --- | --- | --- |
| `setup` | Configure projects, records, or integrations | Guides the necessary setup; reuses existing connections |
| `code-change` | A small, well-understood code or configuration fix | Shows before/after and checks, waits for approval, then implements |
| `project-baseline` | Understand a new project or trace a feature | Investigates structure and sources; a persistent baseline is recorded only when requested |
| `feature-plan` | Plan a feature with a wider impact | Produces a concrete Workplan proposal; does not implement |
| `feature-apply` | Implement an approved feature plan | Makes the agreed changes and reports direct checks |
| `bugfix-plan` | Investigate and plan a complex bug fix | Connects symptoms, cause, code changes, and regression checks |
| `bugfix-apply` | Implement an approved bug fix | Fixes the cause and checks the affected behavior |
| `plan-ui-with-design-system` | Add UI details to feature planning | Maps design states to existing components, tokens, and needed UI checks |
| `implement-ui-with-design-system` | Implement approved product UI | Uses the actual design-system declarations and checks affected states |
| `plan-design-system-component` | Plan a shared design-system component | Compares the official design source with the existing library and proposes its API and variants |
| `author-design-system-component` | Build an approved shared component | Implements the approved API, tokens, and variants without automatically changing consumer apps |
| `apply-workplan-feedback` | Give feedback on current work | Reuses the current work and separates corrections, extra scope, and independent tasks |
| `complete-work` | Explicitly close the current Workplan | Checks the actual result and applies only configured completion adapters |
| `cpm` | Commit or publish Git changes | A bare invocation commits; push and MR/PR creation require an explicit request; never auto-merges |
| `promote-codex-rule` | Make a repeated lesson a reusable rule | Reviews the appropriate rule or skill change before applying an approved update |

The [packaged skill files](plugins/codex/taskweave/skills/) and [shared references](plugins/codex/taskweave/references/) show the actual instructions. This public bundle does not include company-specific Jira, knowledge-publication, or dashboard skills. A company workflow needs its own trusted policies and adapters.

## Where files live and how they connect

Keep three things separate: the installed plugin, the material being worked on, and long-lived work records.

```text
GitHub: chando-park/taskweave
|-- .agents/plugins/marketplace.json       Codex catalog
|-- .claude-plugin/marketplace.json        Claude catalog
`-- plugins/
    |-- codex/taskweave/                   Codex package
    `-- claude/taskweave/                  Claude package
        |-- skills/                       Task procedures
        |-- references/                   Shared and task-specific rules
        |-- core/                         Supporting runtime files
        `-- mcp/                          Local MCP program and dependencies

Your computer
|-- host plugin cache                     Installed copy; do not edit by hand
|-- /example/projects/example-app/         Your code or source material
|-- /example/work-records/example-app/     Existing records, if you connect them
|   |-- Workplans/                        Plans and work results
|   |-- ProductMemory/                    Reusable knowledge, if configured
|   `-- Instructions/                     Project guidance, if configured
|-- ~/.config/ai-workflow/settings.json    Configuration and location index
`-- ~/.local/share/ai-workflow/            Managed state, backups, and optional records
```

This is a logical example, not a promise that installation creates every folder. You choose the project and record locations. New managed records can use the data root's `workspaces/<workspace>/projects/<project>/` structure; existing external records stay at their original location. Compatibility paths retain the `ai-workflow` name.

For a complex task that needs a Workplan, a record can look like this:

```text
<workplan_root>/
`-- YYYYMMDD-short-task-name/
    |-- YYYYMMDD-short-task-name.md        Reason, proposed code, checks, approval
    |-- Completion.md                     Actual implementation/result record
    `-- Details/plan-code.md               Only when longer code detail is useful
```

A Workplan records this particular job. Instructions explain how this project should be worked on. Product Memory holds reviewed, reusable knowledge when that system is configured. They are not three copies of the same document, and completing a task does not silently publish knowledge. Simple fixes can remain entirely in the conversation.

For example, an AI planning an app change reads the selected skill, follows its links to the relevant shared rules, then reads the project's guidance and directly relevant code/design sources. It uses the chosen record location only if a record is needed. It should not search unrelated old tickets to invent a current task.

## MCP and external integrations

MCP is the protocol through which the host calls a tool. Taskweave bundles a local MCP process with three default tools:

| Tool | Purpose |
| --- | --- |
| `context_read` | Read relevant material from a registered workspace or allowed reference |
| `task_current` | Find the current task from explicit identifiers and limited context |
| `record_save` | Save a record with duplicate-request and concurrent-write checks |

These tools do not approve plans, run app tests, or call other MCP servers on their own. File-safety checks do not enforce every action the AI can take through other host tools.

| Integration | Used for | What you must supply |
| --- | --- | --- |
| Serena | Code symbols, callers, and implementations | A working host connection and suitable project/language setup |
| Figma | Design sources and component information | A host connection, access to the file, and the relevant frame/component |
| Jira | Issue lookup and policy-required lifecycle updates | A host connection, issue/project context, and applicable permission |
| Xcode or Android tools | Platform-specific compilation and tests | The project's real toolchain, targets, schemes or Gradle configuration |

Existing connections should be reused. Authentication happens in the host or provider's official flow, not by pasting tokens into Taskweave. Tool visibility, successful authentication, and a successful read are different checks. Platform guidance is included, but a working SDK, simulator, device, or project build is not installed or guaranteed by the plugin.

## Update, remove, and troubleshoot

### Update

Codex:

```sh
codex plugin marketplace upgrade taskweave-marketplace
```

This refreshes the catalog. Check the installed version in the host's plugin manager and apply the available version there; do not assume an already running conversation has changed.

Claude Code:

```sh
claude plugin marketplace update taskweave-marketplace
claude plugin update taskweave@taskweave-marketplace --scope user
```

Start a new conversation after an update. Updating Taskweave does not mean moving or rewriting your existing records.

### Remove

To remove the plugin, use your host's plugin manager or the commands below. Keep work records outside the plugin cache.

```sh
codex plugin remove taskweave@taskweave-marketplace
claude plugin uninstall taskweave@taskweave-marketplace --scope user --keep-data
```

Only run the command for the host you intend to change. These commands are not instructions to delete your projects, external records, or entire `.codex`/`.claude` folders. If a global instruction still links to an installed file, review that link before removing its target. Back up important records before any separate data cleanup.

### Common questions

- **I do not see the skills.** Open a new conversation, check that the plugin is enabled, and select its named skill explicitly.
- **I see two copies.** A previous `taskweave@my-ai-toolbox` installation or direct home skill may coexist with the new marketplace package. Verify the new one before selectively disabling the old Taskweave entry; do not delete all skills.
- **The AI asks where to save records.** Confirm a location only if this task needs records. A plain summary or small fix should not require project-wide setup just to proceed.
- **A service is not connected.** Connect it in the host, or continue only the work that does not require it. Taskweave must report missing evidence rather than invent a successful check.
- **Will this reduce time or tokens?** The design aims to avoid irrelevant reading and repeated work. There is no guaranteed saving; tool latency, model behavior, and the task still matter.

## Data, limitations, and release information

The MCP process runs on your computer, but material returned to the AI is also subject to your Codex/Claude and connected providers' data policies. “Local MCP” does not mean that data can never leave the computer.

Do not put credentials in chats, Workplans, or Product Memory. This package excludes personal work records, company-only skills, product repositories, and authentication files. Documented safeguards and package checks are not a complete security audit.

Current package version: **0.3.1**. Package/MCP tests and macOS CLI installation have been checked. The wording of the rules and a successful installation do not prove end-to-end model behavior in every new task or environment.

Report problems through [GitHub Issues](https://github.com/chando-park/taskweave/issues), without private logs, personal information, or credentials.

No open-source license has been selected for Taskweave itself. Public visibility does not grant an additional project license. Bundled dependencies retain their own licenses and notices: [Codex notices](plugins/codex/taskweave/THIRD_PARTY_NOTICES.md) and [Claude notices](plugins/claude/taskweave/THIRD_PARTY_NOTICES.md).

Maintainers generate this distribution from a separate development source. Users do not need that source checkout to install it. The 0.3.1 bundle is based on source commit `93a1f50aac3a7c40155df8976380cbc5768d8b88` plus the approved small-change approval rules; unrelated uncommitted development changes and the source repository's history are not shipped.
