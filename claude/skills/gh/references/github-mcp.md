# GitHub MCP Tool Reference

Full catalog of `mcp__plugin_github_github__*` tools.

## Pull Requests

| Operation | MCP Tool |
|-----------|----------|
| Create PR | `create_pull_request` (title, body, head, base) |
| List PRs | `list_pull_requests` (state, head, base filters) |
| Read PR | `pull_request_read` (number) |
| Merge PR | `merge_pull_request` (number, merge_method) |
| Update PR | `update_pull_request` (title, body, state) |
| Update branch | `update_pull_request_branch` (number) |
| Review PR | `pull_request_review_write` (approve, request_changes, comment) |
| Reply to comment | `add_reply_to_pull_request_comment` |
| Search PRs | `search_pull_requests` (query) |

## Issues

| Operation | MCP Tool |
|-----------|----------|
| Create issue | `issue_write` |
| List issues | `list_issues` (state, labels, assignee) |
| Read issue | `issue_read` (number) |
| Edit issue | `issue_write` (update mode) |
| Comment | `add_issue_comment` (number, body) |
| Search issues | `search_issues` (query) |
| Sub-issues | `sub_issue_write` |

## Repos & Code

| Operation | MCP Tool |
|-----------|----------|
| Create repo | `create_repository` |
| Fork repo | `fork_repository` |
| List branches | `list_branches` |
| Create branch | `create_branch` |
| List commits | `list_commits` |
| Get commit | `get_commit` (sha) |
| File contents | `get_file_contents` (path) |
| Create/update file | `create_or_update_file` |
| Push files | `push_files` (multiple files in one commit) |
| Delete file | `delete_file` |
| Search code | `search_code` (query) |
| Search repos | `search_repositories` (query) |

## Releases & Tags

| Operation | MCP Tool |
|-----------|----------|
| List releases | `list_releases` |
| Latest release | `get_latest_release` |
| Release by tag | `get_release_by_tag` |
| List tags | `list_tags` |
| Get tag | `get_tag` |

## Other

| Operation | MCP Tool |
|-----------|----------|
| Who am I | `get_me` |
| Get label | `get_label` |
| Teams | `get_teams`, `get_team_members` |
| Issue types | `list_issue_types` |
| Copilot | `assign_copilot_to_issue`, `create_pull_request_with_copilot`, `request_copilot_review`, `get_copilot_job_status` |
