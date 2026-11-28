# Forma — Product Roadmap

**Updated:** 2026-11-28  
**Active product line:** Forma WorkBuddy Edition · `workbuddy/dev`  
**Tracking:** [GitHub Project #18](https://github.com/users/Skyline-Gazer/projects/18) · [Program #217](https://github.com/Skyline-Gazer/Forma/issues/217)  
**Implementation authority:** [WorkBuddy Spec](specs/2026-11-27-workbuddy-edition.md) · [Implementation Plan](workbuddy/IMPLEMENTATION_PLAN.md) · [Reuse Matrix](workbuddy/REUSE_MATRIX.md)

This is the single product roadmap for Forma, not a second WorkBuddy-specific roadmap. It supersedes the legacy native-app roadmap as the active direction. Roadmap inclusion records product intent, not permission to implement, release, migrate production data or incur costs. The current approved Spec and acceptance gates remain authoritative.

## 1. Product direction

Forma is an Agent-native file and knowledge management capability suite. Its primary product form is a WorkBuddy Expert with reusable Skills and the smallest necessary deterministic tooling. AI understands document content, business projects, parties, roles, versions and relationships; deterministic tools provide file identity, evidence, safe execution and recovery.

- WorkBuddy provides the Agent host, conversation/UI, model routing, native tools and security mechanisms. Use Project, Memory, Automation, document tools and ecosystem integrations when their actual capabilities and boundaries fit.
- Original files remain ordinary files in the user's chosen filesystem or OneDrive directory. DEVONthink is optional, preferably indexing originals rather than duplicating them. No mandatory proprietary document store.
- No offline-first requirement, mandatory local model, custom general-purpose runtime, database, search engine, OCR engine, storage driver or standalone GUI. A verified residual gap may justify a narrow tool only after approval of the relevant Spec/Plan.
- User intent, data integrity, security and actual workflow usefulness are the acceptance criteria; a particular algorithm or technology is not a feature by itself.

### Reuse-first decision order

1. WorkBuddy native capabilities.
2. Official Expert/Skill configuration and WorkBuddy ecosystem (including existing connectors/MCP).
3. OS-native services and existing mature tools/open-source projects.
4. Reuse narrow, suitable existing Forma components/contracts.
5. Minimal residual implementation only when the preceding options cannot satisfy the demonstrated requirement.

For each candidate, check official documentation, license, platform/version/plan availability, permission boundary, data egress, maintenance and actual workflow fit. Reuse a proven tool rather than clone its functionality. Documented capability and product-level runtime verification are distinct; do not claim a feature is integrated or accepted merely because the host documents it.

## 2. Active roadmap — Alpha and adoption gates

| Gate | Scope | Tracking | Status as of 2026-11-28 |
| --- | --- | --- | --- |
| M1-A | WorkBuddy host feasibility, installation and script/runtime viability | [#218](https://github.com/Skyline-Gazer/Forma/issues/218) | Closed; host feasibility verified, product security acceptance pending |
| M1-B | Minimal deterministic tooling: inventory, SHA-256, snapshot/plan integrity, exclusive no-replace moves, journal and recovery | [#218](https://github.com/Skyline-Gazer/Forma/issues/218) | Closed; engineering implementation integrated |
| M2 | Expert/Skills, reproducible packaging and CI | [#219](https://github.com/Skyline-Gazer/Forma/issues/219), [PR #222](https://github.com/Skyline-Gazer/Forma/pull/222) | Closed; package integrated |
| M3 | Actual Mac WorkBuddy install, 29-document regression, permission/safety, complete organize/verify/recover workflow and Owner UX approval | [#220](https://github.com/Skyline-Gazer/Forma/issues/220) | Open; not accepted; [#223](https://github.com/Skyline-Gazer/Forma/issues/223) is an open eligibility-classification blocker |
| Phase 4 / Beta candidate | Independent 100–200 document holdout (target 150), three independent runs, incremental update slice | [#213](https://github.com/Skyline-Gazer/Forma/issues/213) | Gated on M3 Owner UX approval |
| Phase 4 / storage | OneDrive File Provider, actual allocated space, selective hydration and fresh-device recovery | [#214](https://github.com/Skyline-Gazer/Forma/issues/214) | Environment/device-gated; not accepted |
| Phase 4 / optional integration | DEVONthink Index, original identity, metadata write/readback and partial-failure handling | [#215](https://github.com/Skyline-Gazer/Forma/issues/215) | Gated on workflow readiness |
| Adoption | Controlled pilot, cost comparison, >=80% human-time saving target and final adoption decision | [#216](https://github.com/Skyline-Gazer/Forma/issues/216) | Gated on #220 and #213–#215 |

The integrated Alpha baseline before this roadmap revision is `ff7a4136f9f4a7ba06787012d783700c457b81de`. The table is a snapshot, not a substitute for live Issues or the implementation plan.

Immediate focus: resolve #223 through its own implementation/review workflow, then rerun #220 against the exact fixed package. Examine missing source-hash handling and demonstrate fail-closed behavior for file-content verification and approved plans; a source review finding is not an already verified runtime defect. Do not proceed to costly holdout or wider development before the existing gates. Preserve the Spec's thresholds, privacy and storage boundaries. No production writes, public release or legacy migration is authorized by this roadmap.

## 3. Long-term product evolution

The following version labels are indicative capability horizons, not fixed releases, deadlines or development authorization. Existing Alpha/Beta gates take precedence; incremental update already has a Phase 4 acceptance slice and must not be deferred solely because its larger evolution is listed under v1.0.

| Horizon | Product outcome | Reuse-first strategy and remaining capability |
| --- | --- | --- |
| Alpha | Safe single-batch document organization | Existing WorkBuddy Expert + minimal deterministic filesystem core; exact duplicates and approval-bound SHA-256 verification |
| Beta | Reliable real-world document organization | Existing independent holdout, incremental slice, OneDrive and optional DEVONthink validation, controlled user pilot |
| v1.0 candidate — Continuous file management | Recognize unchanged/new/changed/moved files across runs; detect exact duplicates across authorized historical batches; persist file identity and fingerprints when justified | Reuse current SHA-256 core, OS metadata and existing fingerprint/index tools; evaluate minimal persistent hash cache only if required. WorkBuddy Project/Memory may supply context but are not an authoritative file identity ledger |
| v1.1 candidate — Knowledge management | Full-text and metadata search, historical project association, version and document relationship discovery, evidence-backed retrieval | WorkBuddy Read/Grep/document tools, OS Spotlight where suitable, optional DEVONthink or mature search adapters; LLM/Skills for semantic relationships; structured durable metadata only where needed |
| v1.2 candidate — Proactive management | Retain user preferences and approved project policies, periodically inspect selected folders and propose actions | WorkBuddy Memory, Project and Automation when supported by the actual client; read-only/proposal-first, no autonomous scheduled production writes; changes still require scoped approval |
| Future — Advanced retrieval | Better semantic discovery, evidence recall and cross-document retrieval | Evaluate existing WorkBuddy knowledge-base/connector ecosystem and mature backends before custom Embedding or Hybrid Retrieval; preserve original-file ownership and privacy, compare coverage, cost and maintenance |
| Research — Storage efficiency | Understand potential space savings across versions while preserving independent byte-exact recovery | Reuse existing versioning/backup capabilities; evaluate CDC/CAS/CDP only with evidence and explicit authorization |

### Capability contracts for future planning

- **Fingerprint and incremental identity:** differentiate content equality (SHA-256), file identity, document version and business association. Exact duplicate groups must not imply automatic deletion. Cache validity must account for file changes/replacement, moves, roots, cloud placeholders and interrupted scans; never substitute cached hashes for safety-critical verification without demonstrated correctness. Avoid unrequested hydration; unknown/unreadable remains explicit.
- **Search and relationships:** distinguish native ad hoc search from a durable index. WorkBuddy LLM/Skills can interpret content and relationships but do not by themselves guarantee persistent, complete retrieval. Preserve source paths and evidence; semantic similarity is not proof of project ownership. Spotlight coverage, OCR, cloud placeholders, metadata, DEVONthink and external knowledge-base compatibility must be verified before adoption.
- **Memory and automation:** store preferences/context in the host when appropriate; exact identity, approval and journal facts remain deterministic. Scheduled inspection is optional and scoped; no silent write, delete, overwrite or scope expansion.
- **Optional integrations:** no mandatory DEVONthink, knowledge-base upload or OneDrive dependency for ordinary organization. Keep external storage/metadata states distinct; do not promise cross-system atomicity or recoverability without proof.

### Existing research backlog

- [#133 — Multi-version incremental storage / CDC / CAS / CDP](https://github.com/Skyline-Gazer/Forma/issues/133): research only, not scheduled. Distinguish semantic version recognition, exact duplicates and actual physical space recovery.
- [#162 — Embedding API / Hybrid Retrieval / lightweight decision models](https://github.com/Skyline-Gazer/Forma/issues/162): research only, not scheduled. Prefer host and mature-tool reuse before a custom index or model; no mandatory local inference. Original issues remain historical references and require explicit scope alignment before activation.

New horizons do not create new implementation Issues or activate existing research automatically. When authorized, map the specific product gap to an existing Issue or create only the necessary new Issue under Project #18, define evidence-based acceptance and derive an implementation plan from an approved Spec. Avoid duplicate tracking.

## 4. Future product forms and lineage

WorkBuddy is the current canonical product line, not an expendable prototype or parallel experiment.

If a standalone App is justified in the future, it must fork/evolve from the **then-current WorkBuddy-era Forma product baseline**, not restart from the legacy SwiftUI roadmap. Here “fork” means a deliberate derived development line (branch or repository only when justified and separately approved), not an instruction to create a fork now.

- Share the product roadmap, domain contracts, reusable Skills/knowledge, file identity and metadata semantics, deterministic safety contracts/tools, test corpus, acceptance evidence and compatible state formats. Keep host-specific adapters separate where there is a demonstrated need; no speculative portability framework now.
- Prefer an existing host or mature file-manager shell and evaluate WorkBuddy Expert/Buddy App or other platform options before a standalone UI/runtime. No assumption that a particular native app, framework or host must be used.
- A standalone application requires evidence of an unmet product/host limitation, reuse and maintenance analysis, licensing review, a separately approved Spec/Plan, and its own product/security acceptance. Existing WorkBuddy gates and shared safety semantics must not be bypassed.
- Legacy SwiftUI source, historical branches and evidence remain preserved as reference material and may yield individual reusable components; they are not the default future product baseline. No legacy PR resurrection, migration, deletion or release without separate approval.

## 5. Governance and evidence

- Canonical active development trunk: `workbuddy/dev`; legacy `dev` and `main` remain frozen under current governance. Follow [AGENTS.md](../AGENTS.md) and the active Spec/Plan; use scoped reviewed changes and existing CI.
- Maintain one product roadmap here. Use existing Project #18 and Issues for actual execution status, blockers and evidence. Do not create a parallel project or duplicate roadmap.
- Record PASS/FAIL/BLOCKED/NOT_VERIFIED honestly. Distinguish code/CI, Mac runtime and Owner product acceptance. No sensitive production material, credentials or private paths in repository evidence; no production writes without authorization.
- Report cross-project ADS lessons when the current WorkBuddy adoption gates yield substantive evidence (particularly #220/#216): capability reuse, host security behavior, measurable workflow outcome, limitations and reproducible evidence. A product-only roadmap update is not itself an ADS issue or a gate requiring ADS feedback. Do not block Forma on ADS for ordinary project-specific work.

## 6. Historical baseline and evidence

The prior roadmap is preserved verbatim in Git history: [Legacy ROADMAP at ff7a4136](https://github.com/Skyline-Gazer/Forma/blob/ff7a4136f9f4a7ba06787012d783700c457b81de/docs/ROADMAP.md). Its E0–E7, P0–P3, I1/I2, R1 and dated authorization history remain evidence, not active instructions for the WorkBuddy product line. Historical engineering/field verification does not imply WorkBuddy product acceptance.

Related references: [Legacy SPEC](SPEC.md), [Legacy PLAN](PLAN.md), [Transition #212](https://github.com/Skyline-Gazer/Forma/issues/212), [Current program #217](https://github.com/Skyline-Gazer/Forma/issues/217). Existing legacy source, documents, issues and branches are intentionally not altered by this roadmap revision.
