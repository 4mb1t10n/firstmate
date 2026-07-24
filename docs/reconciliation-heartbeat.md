# Reconciliation heartbeat

## Purpose

First Mate's event watcher provides immediate crew supervision.

The reconciliation heartbeat adds a periodic GitHub-to-fleet control loop so silence cannot strand authorized work.

Every open issue in every configured project repository is authorized work.

## Components

`bin/fm-reconcile.sh` owns GitHub inventory, cadence selection, durable snapshots, acknowledgement issuance, and reconciliation wake creation.

`bin/fm-reconcile-ack.sh` owns acknowledgement of the latest exact token.

`bin/fm-issue-lease.sh` owns the `in-progress` issue-label lease and its local durable record.

`bin/fm-validation-record.sh` records complete No Mistakes validation for one exact PR head commit.

`bin/fm-pr-auto-merge.sh` owns the strict automatic feature-to-`stg` merge gate.

The agent-only `reconciliation-heartbeat` skill owns the reasoning procedure First Mate follows after the deterministic service wakes it.

## Cadence

The next interval is:

- 10 minutes when an issue lease, crew, validation run, or open PR is active, including when every issue is already closed.
- 30 minutes when open issues exist but no work is active.
- 2 hours only when there is neither open nor active work.

Active work, not the open issue count, selects the fast cadence and requires an acknowledgement: closing the last issue does not end supervision of a crew, a lease, or an open PR.

A validation record counts as active work only while its task still exists, because the record itself is durable evidence that is never cleaned.

`state/reconcile/last.json` persists the next due epoch.

Calling `fm-reconcile.sh --tick` before that epoch is local-only and makes no GitHub request.

The host supervisor may therefore call it on every short supervisor cycle.

## Durable state

`state/reconcile/last.json` is the latest complete inventory.

`state/reconcile/issued.json` is the latest acknowledgement request.

`state/reconcile/last-ack.json` is the latest accepted token.

`state/reconcile/pending` is the watcher latch.

`state/reconcile/leases/*.json` maps GitHub issues to First Mate tasks.

Every lease is cross-checked against the live task ids each cycle.

A lease whose task no longer exists is reported as an orphan to repair rather than accepted as proof of an owner, so a dead crew cannot keep vouching for a remote `in-progress` label.

`state/reconcile/lease-history.jsonl` preserves released lease evidence.

`state/reconcile/validation/*.json` binds complete No Mistakes validation to exact PR heads.

The ordinary durable wake queue carries a `reconcile` record for every actionable tick.

## Watcher integration

The normal watcher checks `state/reconcile/pending` on every poll, after its signal, stale, and check scans.

It exits with the recorded `reconcile:` reason without deleting the latch.

Only a matching acknowledgement removes the latch.

Rearming supervision without acknowledgement therefore resurfaces the same required reconciliation.

The re-surface is bounded: a token this home has not yet surfaced wakes immediately, and the same unacknowledged token wakes again only once every `FM_RECONCILE_RESURFACE_SECS` (default 600).

Between those re-surfaces the watcher keeps triaging crew signals, stale panes, and slow checks normally.

`--tick` owns every durable write.

`--inspect` performs the same inventory as a read-only view: it never writes `state/reconcile/last.json`, never postpones the next due epoch, and never mints an acknowledgement token it could not accept.

An inspect still reports an outstanding token so it can be acknowledged, and reports `required` with a null token when an actionable cycle has not yet been issued by a tick.

## Failure behavior

GitHub inventory failure is `degraded-sync`.

An acknowledgement request older than the configured grace period is `control-plane-failed`.

An open issue inventory is `action-required` until First Mate accounts for the work and acknowledges the cycle.

All merge checks are fail-closed.

The Greptile gate reads only the latest Greptile review or comment posted after the current head commit, and that review must carry its own score field reading exactly 5/5.

A score from an earlier revision, a score from a Greptile lookalike author, a superseded score, and prose that merely contains `5/5` all refuse the merge.

The automatic merge command never edits code or tests and never relaxes a CI condition.

## Process ownership

`bin/fm-process-inventory.sh` classifies heavyweight child processes and resolves ownership by walking the parent chain, because a crew's Chrome or Cypress child usually carries the worktree path only on the crew leader.

A process whose chain resolves to exactly one task worktree is `owned`.

A process whose chain matches several worktrees is `ambiguous`.

The captain pane, the reconciliation's own ancestry, and the supervision plane are `protected`.

Only a process proven to belong to nobody is `unowned`, and only an old `unowned` process is offered as a cleanup candidate.

Age comes from the portable `ps` read, which reports elapsed seconds on Linux only.

On macOS every process therefore reads as age 0 and never becomes a cleanup candidate: ownership and class stay visible, but `degraded-cleanup` is a Linux-host state.

## Host integration

Run the scheduler outside First Mate's workload cgroup.

The scheduler invokes the container's `bin/fm-reconcile.sh --tick --json` and projects `state/reconcile/last.json` into the external supervisor status.

An immediate tick should run on supervisor start, First Mate container start, and First Mate session start.
