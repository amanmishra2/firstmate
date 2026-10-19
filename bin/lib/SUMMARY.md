# bin/lib

Role: Command specific implementation modules for the repo maintenance instrument.

| File | Responsibility | Key Exported Symbols |
| --- | --- | --- |
| `fm-repo-maintenance-common.sh` | Paths, containment, labels, and shared helpers | `rm_sanitize_path`, `rm_sanitize_home_area`, `rm_classify_file`, `rm_scope_root` |
| `fm-repo-maintenance-mine.sh` | OpenCode aggregation and shared mining entrypoint | `rm_run_mine`, `rm_mine_opencode` |
| `fm-repo-maintenance-mine-codex.sh` | Codex rollout projection and completed task aggregation | `rm_mine_codex`, `rm_mine_codex_rollout` |
| `fm-repo-maintenance-rank.sh` | Token heat resolution and presentation | `rm_run_rank`, `rm_run_rank_json` |
| `fm-repo-maintenance-structure.sh` | Tracked layout and summary audit | `rm_run_structure`, `rm_structure_json` |
| `fm-repo-maintenance-sweep.sh` | Weekly report composition and publication | `rm_run_sweep` |
