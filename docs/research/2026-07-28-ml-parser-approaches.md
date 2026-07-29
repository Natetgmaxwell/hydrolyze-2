# ML Approaches for Parsing Hydrolyze Swimming Workouts — Research Brief

**Date:** 2026-07-28
**Author:** MiniMax-M3 (delegated research)
**Context:** Hydrolyze coaching tool — coaches type "3 x 100 FBBF @ 4:30", current parse is a 1,433-line Edge-Function regex pipeline with ~10 iterations of patch fixes, 5 hand-annotated real-input files, iOS Swift MVP, MVP Phase 1.

---

## TL;DR — ranked for THIS product

1. **Regex-first + constrained-decoding small LLM as fallback** — best ROI: keeps the working 80% free, lifts the known edge cases, costs ~$4/mo at projected usage.
2. **PEG / parser-combinator rewrite (wrapping, not replacing, existing regex)** — best cost/latency; the only approach that actually ends the regex-rat's-nest regression loop.
3. **On-device fine-tuned NER (DeBERTa-v3-small or MobileBERT)** — defer until ≥50 annotated set lines; the corpus of 5 files is a cold-start problem for supervised ML.
4. **Small LLM as *abbreviation preprocessor* only** (expand "EZ"/"KDFK" → canonical, then re-feed regex) — narrowest, cheapest LLM use.

---

## 1. Constrained-decoding small LLM as fallback

When `parseWorkoutV2` returns an unresolved `patternType`, leftover free-text fragments, or a sentinel like `INTENSITY_UNRESOLVED`, escalate to a small instruction-tuned model with a JSON-Schema prompt that mirrors the existing `RepGroup` / `Rep` discriminated unions. Engines: `outlines-core` (FSM-based, regex + CFG), `guidance` / `llguidance` (interleaved, ~50 µs/tok), or `llama.cpp` GBNF for local-only. The "constrained decoding is slower than unconstrained" claim is stale — Guidance-AI's JSONSchemaBench (2025) shows XGrammar / llguidance at 6–9 ms/tok vs 15–16 ms baseline on 10K real-world schemas.

- **Models:** Llama 3.1 8B Instruct, Qwen2.5-7B-Instruct, Phi-3.5-mini (3.8B).
- **Libraries:** `outlines-core` v0.2+, `guidance` v0.2+, `llama.cpp` ≥b7700 with GBNF.
- **Latency (hosted):** Groq Llama 3.1 8B = 0.43 s TTFT + 600 tok/s decode (≈150 ms for a 90-token RepGroup JSON) → **p50 ≈ 0.6 s, p95 ≈ 1.2 s**.
- **Cost:** Groq $0.05 / $0.08 per 1M tokens. A 200-token prompt + 90-token output ≈ $0.00002/parse. At 50 sets/session × 100 coaches × 4 sessions/week ≈ **$4/month** — negligible.
- **Biggest risk:** Vendor lock-in & prompt sensitivity. **Mitigations:** (a) keep the regex fallback as ultimate fallback; (b) cache per-coach prompts via the existing `coach_vocabulary` table; (c) drop in local `llama.cpp` Q4 of Qwen2.5-7B (≈100 tok/s on RTX 3090, ≈9 tok/s CPU) for offline-pool-deck use.
- **Direct prior art:** Eklund (KTH 2024) demonstrated Llama 3 8B + JSON Schema + 3 few-shot examples converting CrossFit WODs to JSON with no task-specific training — but warned that "performance is significantly influenced by the examples provided." Our advantage: schema is small and bounded.

## 2. PEG / parser-combinator rewrite (wrap, don't replace)

Replace the regex cascade with a PEG grammar using `ohm-js` (object-oriented grammar extension, left-recursive rules, ~5 KB minified) or `peggy` (PEG.js successor) or `chevrotain` (parser-combinator, JIT-fast). PEGs are *order-sensitive* (unlike regex alternation), produce **excellent position-aware error messages**, and let `coach_vocabulary` become a runtime grammar extension rather than a hidden regex side-channel.

- **Libraries:** `ohm-js`, `peggy`, `chevrotain`, `ts-parsec`.
- **Latency:** <5 ms on warm V8 — **3 orders of magnitude faster than any LLM**.
- **Cost:** $0 / parse, $0 / month. Zero GPU. Zero network. Works at 5 a.m. on bad 4G.
- **Biggest risk:** Migration cost from 1,433 lines of regex + 10 patch iterations. **Critical mitigation: don't rewrite wholesale.** Wrap each existing regex as a PEG *terminal* (`Stroke = "free"|"back"|"breast"|"fly"|"im"`, `Interval = …`), and add PEG layers only for the things regex *cannot* do — `Pattern = "FBBF" | "FBF" | "KDFK"`, `AsProtocol = "as " Num "." Identifier "/" Identifier`, same-as-above chain resolution, FBBF@-style pattern+interval fusion.
- **Why this is ranked above on-device ML:** it directly addresses the *cost-of-iteration* problem the team is paying (one-off-by-one fix per iter). Regex can't grow further without exploding; PEG grows linearly.

## 3. On-device fine-tuned NER — DEFER

BIO-tagging a transformer token classifier (DeBERTa-v3-small ~70M params / ~44 MB INT8 CoreML, or MobileBERT 25M / 25 MB) works in similar recipe-ingredient NER — F1 ≥0.92 on RecipeNLG with ~100k annotated tokens. **But your corpus is 5 files.** That's a cold-start: you'll over-fit to your own 5 writing styles and lose on the long tail. **Hard threshold: don't start until ≥50 hand-annotated set lines (≈1,500 tokens) AND approaches (1) and (2) are exhausted.**

- **When it becomes viable:** DeBERTa-v3-small → CoreML → on-device. P50 ≈ 30–80 ms per line on iPhone 14, zero network, zero cost per additional parse.

## 4. Small LLM as abbreviation preprocessor

A narrower LLM call: extract unknown token spans ("EZ", "loose", "KDFK", "des within 2 sec") and ask the LLM for canonical expansion (`{"EZ":"easy","KDFK":"kick-drill-free-kick"}`). Feed normalised text back into the existing regex. Same model, ~10× cheaper than full structured generation; integrates with the existing `coach_vocabulary` silent-mapping flywheel.

---

## What I would NOT do

- **Don't fine-tune an on-device model now.** 5 files is below the noise floor; weeks of work for marginal F1.
- **Don't host a 70B+ model as the primary parser.** A 70B at $0.59/$0.79 per 1M × 50 sets/session is ≈$0.005/session (affordable), but TTFT of 1–3 s on slower providers kills the "tap-enter-keep-typing" UX.
- **Don't drop the on-device Swift MVP or the Edge Function regex.** They handle the common 80% for free. The right shape is *escalation*, not replacement.
- **Don't run an LLM inside Supabase Edge Functions.** Cold-start network latency is documented at 500–600 ms; running a quantised LLM there is ≈$0.02/parse on CPU. Push model calls to Groq, Cloudflare Workers AI, or Together — not Supabase.
- **Don't adopt grammar-constrained decoding until you've tested the schema against your 5 real-input files.** Early `outlines` versions had 200 ms+ compile time and choked on regex-with-backreferences. JSONSchemaBench shows current engines are fine — but prove it on your real schema first.
- **Don't bury the training-data cost.** Every supervised ML approach in this brief needs labelled data the team doesn't yet have. Treat labels as a first-class deliverable; the bench harness (`scripts/parser-bench/expected.ts`) is the seed.

---

## Citations

1. **Eklund, D. (2024).** *Leveraging LLMs to automatically parse and log fitness workouts from unstructured text — Evaluating Llama 3's few-shot learning performance.* KTH Master's thesis (host: WODMotions). <https://www.diva-portal.org/smash/get/diva2:1939962/FULLTEXT02.pdf> — **most directly relevant prior work; same problem class, same model family.**
2. **Guidance-AI et al. (2025).** *Generating Structured Outputs from Language Models: Benchmark and Studies (JSONSchemaBench).* arXiv:2501.10868. <https://arxiv.org/abs/2501.10868> — 10K real-world JSON schemas, 6 engines (Guidance, Outlines, XGrammar, Llamacpp, OpenAI, Gemini).
3. **Dong, H. et al. (2024).** *Fast JSON Decoding for Local LLMs with Compressed Finite State Machine.* LMSYS / SGLang. <https://www.lmsys.org/blog/2024-02-05-compressed-fsm> — SGLang jump-forward decoding cuts JSON-decoding latency up to 2×.
4. **Recipe-ingredient NER baselines (2024–2025).** *Deep Learning Based Named Entity Recognition Models for Recipes* (arXiv:2402.17447) + *The Impact of NER on Transformer-Based Recipe Classification* (RANLP 2025). <https://arxiv.org/html/2402.17447v2> · <https://aclanthology.org/2025.ranlp-1.22.pdf> — closest analogue to swimming-workout tagging; F1 ≥0.92 with ~100k annotated tokens.
5. **Winfrey, R. (2024).** *Small Models for On-Device Text Classification.* <https://rickwinfrey.com/writings/small-models-for-text-classification> — MobileBERT 25 MB, DistilBERT 65 MB, TinyBERT 15 MB, MiniLM-L6 22 MB (all INT8/CoreML).