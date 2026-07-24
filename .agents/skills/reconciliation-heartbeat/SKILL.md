---
name: reconciliation-heartbeat
description: Agent-only procedure for handling a reconcile wake, maintaining GitHub issue leases, advancing every authorized issue, cleaning completed crews, and applying the strict automatic merge gate.
user-invocable: false
---

# Reconciliation heartbeat

Load this skill whenever a drained wake or watcher result starts with `reconcile:`.

The reconciliation snapshot named in the wake is the deterministic inventory.

Every open issue in every repository listed by the snapshot is authorized work.

## Required cycle

Handle the snapshot in this order.

1. Read the snapshot once and confirm its token matches the wake.
2. Repair orphaned or duplicate ownership before dispatching new work.
3. Reconcile active crews and PRs, prioritizing bounded work closest to completion.
4. Recover stalled crews through `stuck-crewmate-recovery`.
5. Teardown completed or failed crews only through `bin/fm-teardown.sh`, preserving its safety checks.
6. Treat ambiguous process ownership as `degraded-cleanup` and never kill it speculatively.
7. Address PR review, conflict, No Mistakes, Cypress, Migration Drift, Greptile, and CI failures.
8. Reserve eligible issues through `bin/fm-issue-lease.sh reserve` before spawning a crew.
9. Fill memory-safe crew capacity using the existing admission queue.
10. Acknowledge the exact token with `bin/fm-reconcile-ack.sh` only after every required action was performed or durably recorded.
11. Resume the emitted supervision protocol.

Do not acknowledge a snapshot merely because it was read.

An acknowledgement means every issue is accounted for as active, validating, merge-gated, capacity-queued, durably blocked, or resolved.

## Dispatch priority

Use this order:

1. Recover already-started work that can safely continue.
2. Finish PRs needing a bounded fix, conflict resolution, validation rerun, or merge-gate repair.
3. Unblock issues whose dependencies resolved.
4. Honor explicit GitHub priority labels.
5. Select the oldest eligible open issue.
6. Select lighter work when memory cannot admit another heavy crew.

Do not favor new work while nearly complete work remains stranded.

## Issue lease

Reserve with:

```sh
bin/fm-issue-lease.sh reserve <owner/repo#number> <task-id> <project>
```

The `in-progress` label and local lease must correspond to one live task, validation run, linked PR, or durable blocker.

Release only after merge and verified issue closure, or after a deliberate abandoned-work reconciliation:

```sh
bin/fm-issue-lease.sh release <owner/repo#number> <task-id> <reason>
```

Never remove a lease that another valid task owns.

## Cypress policy

Cypress is a required feature-to-`stg` check.

When Cypress fails:

1. Reproduce the user behavior.
2. Determine whether the failure is a product regression, integration defect, environment defect, or obsolete expectation.
3. Fix production code first when the intended behavior remains correct.
4. Change Cypress only when intended product behavior materially changed.
5. Preserve or add coverage for the original regression path.
6. Run the focused scenario and complete required Cypress CI suite.
7. Return through No Mistakes.

Never skip tests, remove meaningful assertions, weaken selectors, inflate retries or timeouts to hide deterministic defects, replace end-to-end coverage with weaker coverage, or update expected output without validating the new behavior.

## Automatic merge

After No Mistakes reports successful validation for the final PR head, record that exact head:

```sh
bin/fm-validation-record.sh <task-id> <head-sha> [run-id]
```

Then use:

```sh
bin/fm-pr-auto-merge.sh <task-id> <pr-url>
```

The gate refuses unless:

- The PR targets `stg`.
- The PR is conflict-free.
- Exact-head No Mistakes evidence exists.
- The latest Greptile review posted after the current head commit carries a score field reading exactly 5/5.
- Migration Drift is present and passing.
- Cypress is present and passing.
- Every reported CI check is green.

Missing Greptile, Migration Drift, or Cypress prohibits automatic merge.

After merge, verify issue closure, release the lease, teardown the crew, clean its resources, and reevaluate capacity.

## Blocking and acknowledgement

A blocker must name its dependency, owner, required action, and recheck condition.

Reevaluate every blocker on every reconciliation wake.

If GitHub inventory failed, process ownership is ambiguous, or First Mate cannot complete the required cycle safely, preserve the pending acknowledgement and expose the corresponding degraded state.
