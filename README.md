# CDPower

**English** | [한국어](README.ko.md)

![CDPower black-and-copper battery logo](plugins/codex/taskweave/mcp/src/viewer/public/wordmark.svg)

**A Codex and Claude Code plugin for reviewing changes before the AI edits files, then following the work through checks, feedback, and acceptance.**

The same workflow supports code changes, research, summaries, and scripts, with sources and checks chosen for the task. Small code changes stay in the conversation: review the proposal, approve it, and inspect the result. Complex changes use a Workplan, a document describing the proposed work.

This README describes the **CDPower 0.3.9** package, the new display name for Taskweave. This is a GitHub-hosted plugin marketplace you add by address, not an entry in OpenAI's or Anthropic's default directory. You do not need to download a ZIP or run a separate hosted server.

[Install and set up](#install-and-set-up) · [Task flow](#how-a-task-moves-through-the-system) · [Examples](#try-it-requests-and-expected-responses) · [Viewer](#read-workplans-in-the-local-viewer) · [Record locations](#where-files-live-and-how-they-connect) · [Update](#update-remove-and-troubleshoot)

The install ID `taskweave`, skill prefixes `$taskweave:` and `/taskweave:`, marketplace names, and GitHub URL stay unchanged so existing installations can update. You do not need to move your code or records. The UI and installation descriptions use **CDPower**.

## What changed in 0.3.9

- The selected flat, horizontal CD battery mark now uses black `#191919` for the C body and copper `#B87333` for the D end and positive terminal. It replaces the lightning symbol in the homepage, favicon, brand page, and downloadable SVG.
- Both host packages include the same logo. Existing layout, UI accent colors, settings, records, and integrations stay unchanged.

## Previous changes in 0.3.8

- The home page, brand page, favicon, and downloadable logo use the CDPower battery-and-lightning symbol. It is branding, not a battery reading or completion percentage.
- A dedicated uninstall skill removes the selected plugin and its owned instruction links together. The shared viewer stays running while another installation needs it; only the last removal stops the verified owned viewer.
- Code, records, settings, and Serena/Figma/Jira connections are preserved. Modified instructions and processes that cannot be identified are left alone.

## What CDPower helps you do

- Review a concrete change instead of approving a vague implementation summary.
- Connect a task to the relevant project rules and sources without reading every document for every request.
- Continue feedback from the current implementation and record, rather than restarting the investigation.
- Separate compilation, behavior tests, visual checks, and unverified work in the result.

Code work, research, summaries, and scripts share a common process, but not the same evidence. A text summary is checked against its source; an app change needs the relevant code or UI checks. CDPower does not turn every writing request into a software project.

The common sequence is: request → relevant sources → proposed changes → approval → work and checks → explanation → feedback and acceptance. It does not require a document, Jira ticket, or app test for every task.

## Install and set up

### Requirements

Have Node.js 22 or newer, Ruby, Git, and the CLI for the host you intend to use. Sign in to that host normally. The plugin includes its MCP dependencies, so a separate `npm install` is not needed.

Packages, MCP connections, and viewer behavior have been checked in isolated macOS tests. Installation on another computer and Windows/Linux operation have not been verified.

### Codex

```sh
codex plugin marketplace add https://github.com/chando-park/taskweave.git
codex plugin add taskweave@taskweave-marketplace
```

Open a new conversation and request `$taskweave:setup`. If typing the name does not select a skill in your client, search for CDPower in its skill selector.

### Claude Code

```sh
claude plugin marketplace add https://github.com/chando-park/taskweave.git --scope user
claude plugin install taskweave@taskweave-marketplace --scope user
```

Open a new conversation and request `/taskweave:setup`.

### What setup needs to know

Setup is optional for a plain conversation task. If you want project and record management, be ready to provide:

1. Provide the parent folder containing your projects. Setup does not assume that everyone uses the same layout.
2. Review the discovered projects and confirm which ones to register. Project IDs are derived from folder names.
3. Setup creates records in the managed location below; you do not need to choose another record folder.
4. Check Serena, Figma, or Jira only if needed. Reuse existing connections and keep external record folders where they are.

For example:

> My projects are in `/example/projects`. Register `example-app` and use CDPower's default record folder. Preserve existing settings and records, reuse the Figma connection, and do not create Jira tickets unless the project policy requires them.

Run `$taskweave:setup` in Codex or `/taskweave:setup` in Claude. Setup registers the confirmed project and creates `Workplans`, `ProductMemory`, and `Instructions` under `~/.local/share/ai-workflow/workspaces/personal/projects/<project>/`. Both hosts use the same settings and records. Previously configured external record folders stay connected; setup does not move or delete them.

Replace the example project path with your own. New records use the default location above; an existing configured location is preserved. On another computer, the same structure is created under that computer's user home. Codex and Claude share records on one computer; CDPower does not synchronize records between computers.

Installing a plugin does **not** automatically replace your global `AGENTS.md` or `CLAUDE.md`. Use its named skills first. Making CDPower the default for all conversations is a separate instruction-linking step that must preserve your existing guidance.

## How a task moves through the system

```text
Your request + current project
          |
          v
AI reads the CDPower skill for this task
          |
          v
AI follows links to relevant rules, project guidance, and sources
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

For example, a feature request leads the AI to `skills/feature-plan/SKILL.md`, the linked explanation and verification rules, and the project's actual code. Once you approve the proposed code and test plan, it uses `feature-apply` to edit and check the implementation. The result must explain every added or changed type, function, branch, and call flow.

The documents do not perform the work themselves. The AI reads the skill and relevant rules, then uses Codex's or Claude's editor, terminal, and connected tools. CDPower's MCP helps it access material and records.

A build passing does not prove that a UI matches Figma. When visual conformance is required, the AI must compare the actual render with an independent design source at a matching state and boundary. Recording the current render as its own answer is not conformance verification.

Approval to implement does not also authorize commit, push, MR/PR creation, external publication, Jira closure, or knowledge publication. Those actions need their own applicable permission. Ordinary conversation results do not require a formal closing ceremony.

## Try it: requests and expected responses

The following are illustrative examples, not results from a real project. Select a CDPower skill explicitly if you want to make sure that workflow is used. In Codex, use `$taskweave:<skill>`; in Claude Code, use `/taskweave:<skill>`.

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

## Read Workplans in the local viewer

When the host starts CDPower's MCP, it starts the local viewer and opens the browser once. A running viewer is reused across Codex and Claude without opening a duplicate tab. This happens on MCP startup, not merely when you install the plugin or open any conversation.

The viewer shows recent work, search, status, rendered Markdown details, code-flow pages, and recorded test results. It is read-only: it does not edit plans, approve work, or change tickets. The original Markdown is not replaced with HTML; the viewer renders it for reading inside the browser. It listens only on the local computer; if a port belongs to another application, that application is left alone. A viewer startup error does not block the MCP's record tools. Set `TASKWEAVE_VIEWER_AUTO_OPEN=0` in the MCP environment to disable automatic startup and browser opening.

### Open the viewer again

Ask Codex or Claude:

> Find the running CDPower viewer's address and open it in the browser. Do not change records or settings.

The default runtime file `~/.local/share/ai-workflow/viewer/service.json` contains the address in `url`. If you configured a different data location, use its `viewer/service.json` instead. Do not assume port `4317`; another port may have been selected. Closing the browser does not necessarily stop the viewer.

If automatic startup fails, check the CDPower MCP connection and the default log at `~/.local/share/ai-workflow/viewer/service.log`. To run a separate viewer manually, replace both paths below with your installed plugin and record directory:

```sh
node "/installed/plugin/folder/mcp/src/viewer/main.mjs" \
  --root "/records/Workplans"
```

Open the address printed in the terminal. This manual process is separate from the managed viewer; stop it with Ctrl+C in that terminal. Records are not deleted.

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
|-- ~/.local/share/ai-workflow/workspaces/personal/projects/example-app/
|   |-- Workplans/                        Plans and work results
|   |-- ProductMemory/                    Reusable knowledge, if configured
|   `-- Instructions/                     Project guidance, if configured
|-- ~/.config/ai-workflow/settings.json    Configuration and location index
`-- ~/.local/share/ai-workflow/            Managed state, backups, and viewer state
```

Installing the plugin supplies its files; setup creates project record folders after you confirm the project. You select the folder containing your projects, not a new record location. Existing external records stay at their original location. The shared configuration is `~/.config/ai-workflow/settings.json`. Compatibility paths retain the `ai-workflow` name.

For a complex task that needs a Workplan, a record can look like this:

```text
<workplan_root>/
`-- YYYYMMDD-short-task-name/
    |-- YYYYMMDD-short-task-name.md        Reason, proposed code, checks, approval
    |-- Completion.md                     Actual implementation/result record
    `-- Details/plan-code.md               Only when longer code detail is useful
```

For a new task linked to a ticket, use `YYYYMMDD-<ticket-key>-short-task-name` for the folder and main file. If you designate `QA-123` as the task's ticket, that key stays unchanged. Existing document names are not renamed in bulk.

A Workplan records this particular job. Instructions explain how this project should be worked on. Product Memory holds reviewed, reusable knowledge when that system is configured. They are not three copies of the same document, and completing a task does not silently publish knowledge. Simple fixes can remain entirely in the conversation.

For example, an AI planning an app change reads the selected skill, follows its links to the relevant shared rules, then reads the project's guidance and directly relevant code/design sources. It uses the chosen record location only if a record is needed. It should not search unrelated old tickets to invent a current task.

## Skills: choose by the work you need

The bundle contains 16 personal workflow skills plus `setup`. The names below work with the Codex `$taskweave:` or Claude `/taskweave:` prefix.

| Skill | When to use it | What it does |
| --- | --- | --- |
| `setup` | Configure projects, records, or integrations | Guides the necessary setup; reuses existing connections |
| `code-change` | A small, well-understood code or configuration fix | Shows before/after and checks, waits for approval, then implements |
| `explain-code` | Understand code, a Workplan proposal, or implementation results | Shows the execution/data/branch flow first and connects each step to code, rationale, and tests; HTML is only the display medium |
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
| `uninstall` | Stop using CDPower or the former Taskweave | Removes the selected host installation and owned links while preserving shared use and records |
| `cpm` | Commit or publish Git changes | A bare invocation commits; push and MR/PR creation require an explicit request; never auto-merges |
| `promote-codex-rule` | Make a repeated lesson a reusable rule | Reviews the appropriate rule or skill change before applying an approved update |

The [packaged skill files](plugins/codex/taskweave/skills/) and [shared references](plugins/codex/taskweave/references/) show the actual instructions. This public bundle does not include company-specific Jira, knowledge-publication, or dashboard skills. A company workflow needs its own trusted policies and adapters.

## MCP and external integrations

MCP is the protocol through which the host calls a tool. CDPower bundles a local MCP process with three default tools:

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

Existing connections should be reused. Authentication happens in the host or provider's official flow, not by pasting tokens into CDPower. Tool visibility, successful authentication, and a successful read are different checks. Platform guidance is included, but a working SDK, simulator, device, or project build is not installed or guaranteed by the plugin.

## Update, remove, and troubleshoot

### Update

Codex:

```sh
codex plugin marketplace upgrade taskweave-marketplace
```

This refreshes the catalog. In Codex's plugin manager, apply the CDPower update and confirm version **0.3.9**; do not assume an already running conversation has changed.

Claude Code:

```sh
claude plugin marketplace update taskweave-marketplace
claude plugin update taskweave@taskweave-marketplace --scope user
```

Confirm version **0.3.9**, then start a new conversation and select the CDPower skill you need. Updating CDPower does not mean moving or rewriting your existing records. If you previously linked global instructions manually to a version-specific cache folder, ask setup to inspect that link; installing a newer package alone does not retarget an old manual link. Updating supplies the public rules, not your company-specific policies or service logins; those need their own setup on each computer.

### Remove the plugin, owned links, and viewer

**Recommended: run the uninstall skill before removing the plugin.**

- Codex: select `$taskweave:uninstall` and ask, “Remove CDPower from this Codex installation. Keep my records.”
- Claude Code: run `/taskweave:uninstall` with the same request.
- To remove both, explicitly ask, “Remove CDPower from both Codex and Claude. Keep my records.”

The AI identifies the exact plugin and marketplace before running the host's official removal command. After a removal is confirmed, it cleans up only owned instruction blocks and legacy links for that installation. It preserves other instructions, modified links, and anything whose ownership cannot be established, then reports what remains. If another host or duplicate installation still uses the shared viewer, it keeps it running. Only the last removal can stop a viewer whose service, instance, and actual process identity match. A PID or port alone is not enough.

Your code, Workplans, Product Memory, user-authored project guidance, settings, credentials, and Serena/Figma/Jira connections stay in place. Browser tabs are not closed. Start a new conversation afterward: removing files does not erase instructions already read into the current conversation.

For terminal use, supply the actual installed plugin directory. The first command previews the operation without cleanup.

```sh
node "/installed/plugin/folder/mcp/src/installation.mjs" --client codex --uninstall
# Apply to that same target
node "/installed/plugin/folder/mcp/src/installation.mjs" --client codex --uninstall --apply
```

Use `--client claude` for Claude only or `--client both` for both. If one host has multiple marketplace installations, select an exact choice from the preview and pass it with a single host, for example `--plugin-selector taskweave@taskweave-marketplace`. Do not guess which marketplace to remove.

**Using only the marketplace's uninstall button, `codex plugin remove`, or `claude plugin uninstall`:** this removes the plugin but does not establish that external instruction links and the detached viewer were cleaned up. The documented hooks do not specify a plugin-uninstall event, so use the dedicated removal path. If you already removed it, inspect remaining links with a surviving installed removal tool, or identify the exact owned links before manual cleanup. Do not delete entire instruction files or the `.codex` and `.claude` directories.

### Common questions

- **I do not see the skills.** Open a new conversation, check that the plugin is enabled, and select its named skill explicitly.
- **I see two copies.** A previous `taskweave@my-ai-toolbox` installation or direct home skill may coexist with the new marketplace package. Verify the new one before selectively disabling the old CDPower entry; do not delete all skills.
- **The AI asks where to save records.** Confirm a location only if this task needs records. A plain summary or small fix should not require project-wide setup just to proceed.
- **A service is not connected.** Connect it in the host, or continue only the work that does not require it. CDPower must report missing evidence rather than invent a successful check.
- **Will this reduce time or tokens?** The design aims to avoid irrelevant reading and repeated work. There is no guaranteed saving; tool latency, model behavior, and the task still matter.

## What changed in 0.3.6

Codex and Claude receive packages built from the same shared rules. This release includes:

- Concrete code and responsibility decisions before approval. If implementation requires a new design outside that agreement, the AI must explain it and ask before proceeding.
- Explanations of all added or changed types, functions, branches, and call flows, with test lists, actual results, and measured coverage—or an explicit “not measured.” Complex changes can link a code-flow visualization to the real code and tests.
- Plain-language progress updates: what was checked, what went wrong, what happens next, and how that affects the code or records.
- Reuse of the existing ticket key you designate, including keys outside an implementation project's usual prefix. Existing tickets and document names are not automatically renamed.
- Shared project records for both hosts and a read-only local Workplan viewer that starts when the CDPower MCP starts.

These rules are included in the public package. Company-specific adapters and credentials remain separate.

## Data, limitations, and release information

The MCP process runs on your computer, but material returned to the AI is also subject to your Codex/Claude and connected providers' data policies. “Local MCP” does not mean that data can never leave the computer.

Do not put credentials in chats, Workplans, or Product Memory. This package excludes personal work records, company-only skills, product repositories, and authentication files. Documented safeguards and package checks are not a complete security audit.

**0.3.9 checks:** 5 viewer-server, 14 MCP, and 2 packaging tests passed: 21 distinct tests with no failures or skips in the final results. The logo and brand page were checked against the selected concept in desktop and 320px browser views. Packaging/build-module coverage was 95.49% line and 80.83% branch coverage; SVG/HTML/CSS coverage was not measured. Other computers and Windows/Linux were not independently tested.

**Historical 0.3.8 checks:** 32 installation tests, 13 legacy-link tests, 12 viewer-lifecycle tests, 14 MCP tests, 2 packaging tests, and 5 viewer-server tests passed: 78 distinct tests, with no failures or skips in the final runs. Removal tests used isolated temporary homes and child processes; they did not uninstall the maintainer's live setup. Latest installation-module coverage was 92.42% line and 78.22% branch coverage, not whole-project coverage. The homepage, battery logo, search, and work details were also checked in a browser. Installation and behavior on another computer or Windows/Linux have not been independently verified.

**Historical 0.3.6 checks:** 2 packaging tests, 14 MCP tests, 9 viewer-lifecycle tests, and 4 viewer-server tests passed: 29 in total. These are tests of the plugin, not results for your app. They do not guarantee that every AI response follows the instructions. You retain final judgment, and the host's permissions still apply.

Report problems through [GitHub Issues](https://github.com/chando-park/taskweave/issues), without private logs, personal information, or credentials.

No open-source license has been selected for CDPower itself. Public visibility does not grant an additional project license. Bundled dependencies retain their own licenses and notices: [Codex notices](plugins/codex/taskweave/THIRD_PARTY_NOTICES.md) and [Claude notices](plugins/claude/taskweave/THIRD_PARTY_NOTICES.md).

Maintainers generate this distribution from a separate development source. Users do not need that checkout to install it. Version **0.3.9** corresponds to source commit `8b8f3cd`, with the selected black-and-copper CD battery logo. It retains the shared rules and safe removal flow from 0.3.8 (source `4871d7a`). The repository address and installation IDs remain unchanged so existing marketplace subscriptions can update in place. Personal records, credentials, and source Git history are not shipped. Historical version 0.3.6 used source baseline `e6f3514`, plus release-version metadata.

Official installation and update guidance: [OpenAI plugin packaging](https://developers.openai.com/plugins/build/plugins), [Claude Code plugin management](https://code.claude.com/docs/en/discover-plugins).
