---
name: precommit-checklist
description: Use before committing or finishing a task in AbyssalWatch. Runs `mix precommit` (compile --warnings-as-errors, deps.unlock --unused, format, test) and verifies each step passes before claiming the work is done. Triggers when user says "commit", "ready to commit", "wrap up", "finish", "done with changes", or before opening a PR.
---

# precommit-checklist

Rigid skill. Follow exactly. Do not skip steps. Do not claim success without evidence.

## When to use

- User says they are done, ready to commit, ready to push, or ready to open a PR
- You have just finished a logical chunk of code and need to verify it's clean
- Before any `git commit` on AbyssalWatch

## The `mix precommit` alias

Defined in `mix.exs`:

```
precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
```

Four steps, each must pass.

## Procedure

Execute each step in order. Stop on first failure and fix before continuing.

1. **Run the alias**

   ```bash
   mix precommit
   ```

2. **If `compile --warnings-as-errors` fails:**
   - Read the warning. Do not silence it with `@compile`.
   - Fix the underlying issue (unused variable → prefix with `_`, unused alias → remove, etc.)
   - Re-run `mix precommit`

3. **If `deps.unlock --unused` modifies `mix.lock`:**
   - That's fine — stage the change: `git add mix.lock`
   - Continue

4. **If `format` modifies files:**
   - Stage the formatted files
   - Continue

5. **If `mix test` fails:**
   - Do NOT mark the task complete
   - Fix the failing tests OR fix the code that broke them
   - Re-run `mix precommit` from step 1

6. **Verify clean exit**

   ```bash
   echo "precommit exit: $?"
   ```

   Must be `0`. If non-zero, you are not done.

7. **Show evidence to the user**

   Quote the final lines of test output (e.g. `Finished in X seconds`, `N tests, 0 failures`) before claiming the changes are ready.

## Red flags

| Thought | Reality |
|---------|---------|
| "The warning is unrelated to my change" | Fix it anyway, or surface it explicitly. Don't hide it. |
| "Tests were already failing before my change" | Verify with `git stash && mix test` — don't assume. |
| "I'll commit and fix in a follow-up" | No. The repo's contract is `mix precommit` passes on every commit. |
| "`--no-verify` will skip the hook" | Forbidden unless the user explicitly asks. |

## What this skill does NOT do

- Does not run `git commit` for you. You still need explicit user approval to commit.
- Does not run dialyzer, credo, or any other tool not in the `precommit` alias.
- Does not modify code to make tests pass — only points out failures.
