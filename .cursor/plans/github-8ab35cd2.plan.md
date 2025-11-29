<!-- 8ab35cd2-4619-488d-b69c-aa59dc03230b b85241b2-16f9-44ed-8c04-5e2f4a3857ce -->
# GitHub Deep AI Context Integration

## Goals

- Use GitHub (PRs, commits, branches, files, diffs) as a powerful but optional integration for AI context in chat, tickets, and meetings where it clearly adds value.
- Let users `@` attach any entity (ticket, user, PR, commit, branch, file) and have the AI use it deeply without extra friction.
- Keep responses concise and token-efficient by summarizing GitHub data instead of dumping raw diffs.

## 1) Add a GitHub AI context service

- Create `backend/app/services/github_ai_context.py` to normalize GitHub entities into `EntityContext` and rich summaries.
- Implement helpers like:
- `build_pr_entity(pr: GithubPullRequest, linked_ticket_ids: list[int]) -> EntityContext`
- `build_commit_entity(commit: GithubCommit, linked_ticket_ids: list[int]) -> EntityContext`
- `build_branch_entity(branch: GithubBranch, repo: GithubRepo) -> EntityContext`
- `build_file_entity(blob: GithubFileBlob, repo: GithubRepo) -> EntityContext`
- For PRs/commits, pull basic stats (changed files, additions/deletions) via existing diff helpers when needed, but keep the stored summary compact.
- Follow the existing `EntityContext` patterns used in `/ai/entities/search` so UI and AI share one shape.

## 2) Expand GitHub-backed entity search for @-picker

- Extend `/ai/entities/search` in `backend/app/api/routes/ai.py` to also surface `GITHUB_FILE` entities once file blobs exist for a repo.
- Route PR/commit/branch/file `EntityContext` construction through the GitHub AI context service, so the @-picker can show rich display names and summaries.
- Keep existing behavior (tickets, users, sprints, labels) unchanged while adding GitHub types into the shared search/browse experience.

## 3) Add deep GitHub tools for the agent

- In `backend/app/tools/definitions.py`, define new tools:
- `search_github` → wraps `/integrations/github/search` to find commits, PRs, branches, files.
- `get_github_pr_details` → takes a PR id or `(repo_id, pr_number)` and returns metadata + summarized diff and linked tickets.
- `get_github_commit_details` → similar for commits, using commit diff helpers.
- `get_github_file_content` → wraps `/integrations/github/file`, returns truncated content + metadata.
- `compare_github_refs` → wraps `/integrations/github/repos/{repo_id}/compare`, returns high-level stats and commit/file summaries.
- In `backend/app/tools/executors.py`, implement corresponding executors that:
- Call the FastAPI endpoints or use DB + `integrations/github.py` directly.
- Post-process raw GitHub data into compact JSON structures suitable for prompts (no full diffs by default).
- Update `_get_tool_status_message` in `backend/app/services/agent.py` to include user-friendly messages for the new tool names.

## 4) Teach the agent when to use GitHub tools (including intelligent search)

- Update `build_agent_system_prompt` in `backend/app/services/agent.py` to:
- Document the new tools under READ tools with clear instructions and examples.
- Add behavior rules such as:
- For ticket status/progress questions, use `get_github_activity` and, if needed, `get_github_pr_details` / `get_github_commit_details` for deeper context.
- For questions like “what changed around X / this feature / this bug?” or “what changed in code last week?”, prefer `search_github` first to discover relevant PRs/commits/branches/files, then call detail tools on the top hits.
- For file/module questions (“what does this file do?”), use `get_github_file_content` and summarize.
- For release / branch diff questions, use `compare_github_refs` and summarize.
- Emphasize that the agent should **proactively call `search_github`** when the user’s question is clearly about recent changes, code behavior, or implementation status, even if no ticket, PR, or commit id is explicitly mentioned.
- Rely primarily on the LLM’s tool-calling behavior (driven by the updated prompt) for “intelligent search”, rather than hard-coded heuristics, so it can generalize to new phrasings.

## 5) Wire GitHub into meeting → ticket drafting

- In `backend/app/services/meeting_ticket_ai.py`, before building the meeting transcript prompt:
- Resolve a set of relevant tickets for the meeting (e.g. active tickets in the same workspace/group, or tickets explicitly referenced via metadata when available).
- For those tickets, load linked PRs/commits via `tickets_github_prs` and `tickets_github_commits` and summarize them using the GitHub AI context service.
- Append a "Relevant GitHub context" section to the synthetic user message sent into `TicketDraftingService`, listing per-ticket GitHub status (open PRs, recent commits, repos, high-level change summaries).
- Keep the rest of the meeting → `TicketDraft` pipeline unchanged so existing human-in-the-loop flows continue to work.

## 6) Use GitHub as latent context in normal chat

- In the `send_message` handler in `backend/app/api/routes/ai.py`:
- Preserve current `attached_ticket_ids` and `attached_entities` behavior so tickets and arbitrary entities (including GitHub PRs/commits/branches/files) are available as structured context.
- When tickets are attached, optionally precompute a short, textual GitHub status summary (via `get_ticket_github_activity` + GitHub AI context service) and prepend it to the system or user message for the agent.
- For **general questions without attached tickets or explicit IDs** (e.g. “what changed in billing recently?”, “are we close to shipping search revamp?”), rely on the updated system prompt so the agent can:
- First use `search_tickets` and/or `search_github` to discover relevant work and GitHub activity from the query text alone.
- Then call detail tools (`get_github_pr_details`, `get_github_commit_details`, `get_github_file_content`) as needed before answering.
- Avoid hard-coded keyword heuristics at the API layer initially; instead, monitor usage and consider adding light heuristics later if the agent under-calls GitHub tools for clearly code-centric questions.

## 7) Optional: surface GitHub entities used by AI in the UI

- On the frontend chat UI, extend the existing representation of `attached_entities` and tool events to:
- Show which GitHub entities were attached by the user via `@`.
- Optionally show which extra GitHub entities the agent looked up via tools (e.g. as small badges under the assistant message, like “Looked at PR #45, commit abc1234”).
- On ticket and meeting pages, add a compact "GitHub activity" panel (driven by `GET /tickets/{id}/github/activity` and the new context service) so users can see the same information the AI is using.