# When Flux Can't Update a Job: A Kubernetes Immutability Lesson

I shipped a small content update to my chat-mode personal site — just markdown files in `content/`, the kind of change the build pipeline is supposed to handle without me thinking about it. The PR merged, GitHub Actions built a new image, Flux's Image Update Automation picked up the new tag and committed it back to my GitOps repo, and I went to make a coffee.

When I came back, the live site was still answering questions from the old content.

Here's what was happening, why it happened, and the one-line fix that prevents it from happening again.

---

## 1. The symptom

The personal site has a small in-cluster Job called `content-ingest` that re-runs whenever the app image updates. It loads markdown from `content/`, embeds chunks via OpenAI, and upserts them into Qdrant. Standard idempotent ingest pattern.

After the merge, I tailed the Job's logs:

```bash
kubectl --context homelander -n personal-site logs job/content-ingest
# [ingest] loaded 6 chunks from /app/content
# [ingest] done. 6 active, 0 pruned.
```

Six chunks. The new content has seventeen. So the Job ran successfully — but it ran against the *old* image. Something hadn't propagated.

A quick image check confirmed it:

```bash
kubectl --context homelander -n personal-site get job content-ingest \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# quydoan/personal-site:4a27069-1777163996   <- previous build, not the new one
```

Flux *thought* the cluster was up to date, but the Job spec hadn't been updated to the new image. The Deployment for the web container also hadn't rolled. Both were stuck on the old tag.

---

## 2. The diagnosis

Flux's Kustomization status spelled it out:

```bash
kubectl --context homelander -n flux-system get kustomization personal-site \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

```
"reason": "ReconciliationFailed",
"status": "False",
"type": "Ready",
"message": "Job/personal-site/content-ingest dry-run failed (Invalid):
            Job.batch \"content-ingest\" is invalid: spec.template:
            Invalid value: {...}: field is immutable"
```

There it is. **`spec.template` is immutable on a Kubernetes Job once it's been created.** Flux's `kubectl apply --dry-run=server` rejects the change with a 422, and the reconciliation fails. The Job sits there indefinitely with the old spec; the Deployment doesn't roll because it depends on the same Kustomization succeeding.

The retry loop that *looked* healthy in `flux get kustomizations` was actually a slow hammer hitting a wall.

---

## 3. Why Jobs are immutable

This is by design, not a bug. A Job represents a unit of work that ran (or is running) with a particular configuration. If you could mutate the pod template after the fact, the Job's "this is what I ran" record would be a lie. So the Kubernetes API server enforces immutability on `spec.template`, `spec.completions`, `spec.selector`, and a few other fields.

The intended pattern for "run this same Job with a new image" is one of:

1. **Delete the old Job and create a new one with the same name.**
2. **Create a Job with a different name** — typically by suffixing a hash or tag.
3. **Use a CronJob**, where each scheduled run is a brand-new Job underneath.

GitOps tooling has to pick one. By default Flux just runs `kubectl apply`, which means it falls straight into the immutable-spec trap on every image update.

---

## 4. Two fixes I considered

### Option A: Name-suffix the Job per image tag

Give the Job a name like `content-ingest-b244924`, where the suffix is the image tag. Each new image creates a new Job; old ones get pruned by Flux when their previous name disappears from the manifest, or by the Job's own `ttlSecondsAfterFinished`.

The catch: Kustomize's `nameSuffix` field applies to *every* resource in the kustomization — Deployment, Service, ConfigMap, Ingress, the lot. To scope the suffix to just the Job I'd need to break the Job out into its own sub-kustomization and import it as a component. That's a meaningful structural change to the repo for a problem that has a simpler answer.

### Option B: Tell Flux to delete-and-recreate on immutability

Flux supports a per-resource annotation:

```yaml
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/force: "Enabled"
```

Setting this on a resource tells the kustomize-controller: *if you can't update this resource because of an immutability error, delete it and recreate it.* One annotation, no structural changes to the repo, no new resources, no Kustomize gymnastics.

The behaviour is exactly what I want for this Job. Every time a new image tag comes through, Flux replaces the Job with a fresh one carrying the new spec. The Job's existing `ttlSecondsAfterFinished: 3600` means I still have logs from the previous run for an hour after the new run finishes — enough audit trail for this use case.

---

## 5. Why I picked Option B

Three reasons:

1. **Smaller surface area for the fix.** One annotation versus a sub-kustomization. Less to remember and less to read in six months.
2. **No accumulating state.** With name-suffixing there'd be a sliding window of past Jobs in the namespace; with the force annotation there's always exactly one Job. Cleaner steady state.
3. **It's the same delete-and-recreate I would do by hand.** When the Kustomization first failed, I unblocked it manually with `kubectl delete job content-ingest && flux reconcile kustomization personal-site --with-source`. The force annotation just tells Flux to do that for me on every future deploy.

---

## 6. The change

In `apps/personal-site/base/ingest-job.yaml`:

```diff
 apiVersion: batch/v1
 kind: Job
 metadata:
   name: content-ingest
   namespace: personal-site
+  annotations:
+    kustomize.toolkit.fluxcd.io/force: "Enabled"
 spec:
   backoffLimit: 2
   ttlSecondsAfterFinished: 3600
   ...
```

That's the whole patch. Commit, push, let Flux reconcile, and the next image-update cycle proves the fix:

```bash
flux --context homelander reconcile kustomization personal-site --with-source
kubectl --context homelander -n personal-site get job content-ingest -o wide
# new UID, new image tag, new pod, fresh logs
```

I'm leaving the same annotation off the Deployment because Deployments handle image updates correctly via rolling updates — they don't have an immutability problem. The annotation is doing real work only on resources where Kubernetes refuses in-place updates.

---

## 7. The lesson

The thing I almost missed: **this category of bug is invisible until you ship a new image.**

The first time you create the Job in a fresh cluster, everything works. The CI pipeline is green. The pod runs. The logs are clean. Then you don't change anything for a week, and the bug doesn't fire because nothing's trying to update the Job.

The next change to the Job spec — a new image tag, a tweaked command, an extra environment variable — is the one that fails. And you find out about it not via a CI failure but via "the live site is still showing old data" hours later, after a coffee.

If I were starting again, I'd add the force annotation to **every Job and CronJob in the GitOps repo by default**. The cost is zero on resources that can be updated in place (the annotation just isn't exercised), and it removes a class of silent stuck reconciliations you only learn about when something goes visibly wrong.

The broader version of the lesson is one I keep relearning: GitOps gives you a feedback loop that's tight and obvious for *application* changes — rolling deployments, container restarts, observable in `kubectl get pods`. But the loop for *resource-shape* changes — immutable fields, CRD updates, controller-side validation — can be invisible. Flux is shouting in `flux get kustomizations` and `kubectl describe`; the trick is remembering to check.

If you're running anything that creates Jobs from a GitOps source — ingest pipelines, schema migrations, one-shot data backfills, anything where the Job re-runs on each deploy — go add the force annotation now. Future you will thank you.
