<div align="center">

<img src="starfish.svg" alt="Starfish" width="200" />

# Starfish

**A local-first agent runtime with built-in review, memory and self-repair, written entirely in CnR.**

![Language](https://img.shields.io/badge/language-CnR-ff7a45)
![Runtime](https://img.shields.io/badge/runtime-local%20GGUF-2ea043)
![API](https://img.shields.io/badge/API-HTTP%2FJSON-0969da)
![Bind](https://img.shields.io/badge/bind-127.0.0.1-6e7681)

</div>

---

## Contents

- [Overview](#overview)
- [Biological model](#biological-model)
- [Quick start](#quick-start)
- [Architecture](#architecture)
- [Arms](#arms)
- [Long-form generation and review](#long-form-generation-and-review)
- [Indicators](#indicators)
- [Memory and skills](#memory-and-skills)
- [Progression](#progression)
- [Arm lifecycle](#arm-lifecycle)
- [Tools and task syntax](#tools-and-task-syntax)
- [HTTP API](#http-api)
- [Configuration](#configuration)
- [Security model](#security-model)
- [Project layout](#project-layout)
- [Testing](#testing)
- [Why CnR](#why-cnr)

---

## Overview

Starfish is an agent runtime built around a local language model. Instead of a single loop around a single model call, work is distributed across a ring of specialized workers called *arms*, coordinated by a central scheduler. Arms execute, review, archive, forge tools and plan; every result is checked before it is accepted, and every failure feeds back into scheduling, memory and future prompts.

The design is based on the anatomy and physiology of a sea star. Each module is named after the structure it models, and the naming is functional. See [Biological model](#biological-model).

### Features

| Capability | Description |
|---|---|
| Role-restricted arms | Executor, reviewer, archivist, blacksmith and planner. Each arm can only run the tools assigned to its role. |
| Two-stage quality control | Deterministic, model-free checks run first. A reviewer arm inspects content second. |
| Error handling loop | A faulty part is discarded, the responsible arm is penalized, a lesson is recorded, and the part is regenerated with the correction in the prompt. |
| Persistent memory | Lessons are recalled by relevance and compacted by the archivist when they exceed their budget. |
| Self-generated skills | Repeated errors are distilled into short reusable rules. Skills are scored by outcome and discarded if they do not help. |
| Progression | Accumulated XP unlocks five levels that scale arm count, token budgets, step limits and context. |
| Arm replacement | Arms that accumulate too much penalty are removed and replaced by a new arm that inherits from the best performers. |
| Local and sandboxed | Runs a local GGUF model. File access is confined to one directory and HTTP is restricted to localhost. |
| Single language | The entire agent is CnR. No glue scripts, no external orchestration framework. |

---

## Biological model

Starfish uses the body plan of a sea star (class Asteroidea) as its architectural model. The analogy is structural and functional. It is a naming and design guide, not a biological simulation.

A sea star has no single central brain. Its body is radially symmetric, with typically five arms, and each arm carries its own nerve and sensory structures, so the arms act with a degree of independence while remaining coordinated through a central ring. It moves, feeds and exchanges fluids through the *water vascular system*, a hydraulic network of canals that ends in the tube feet. Water enters this network through the *madreporite*, a sieve plate on the upper surface of the body. From there it flows through a ring canal around the mouth and then along a radial canal into each arm. A *hemal system* with its own ring runs alongside. Sea stars can also regenerate lost arms, and they develop from larvae to adults.

Starfish maps these traits onto its design as follows.

| Biological trait | Counterpart in Starfish |
|---|---|
| Madreporite: sieve plate through which water enters the body | `MADREPORITO.cnr`: filters, size-limits and parses everything that enters the system. |
| Hemal ring: central ring that links the body's parts | `HEMALRING.cnr`: the ACC, which coordinates arm selection, review, penalties and regeneration. |
| Radial canals: carry water from the ring into each arm | `CANAL.cnr`: the only bridge from the ring to an arm, restricted to that arm's worklist. |
| Ambulacral system and tube feet: the actuators the arms use to act on the environment | `AMBULACRO.cnr`: the tool layer through which arms read, write, call the model and manage memory. |
| Interradii: the regions between the arms | `INTERRADII.cnr`: the environment shared by the arms: logging, workspace paths, progress and pace. |
| Five radially symmetric, semi-independent arms | A ring of five specialized arms, each with its own weights, personality, load and pain, growing to nine. |
| Arm regeneration | A removed arm is replaced in the same slot by a new arm that inherits from the best-performing arms, with mutation. |
| Development from larva to adult | Five levels from Larva to Elder, with budgets that grow at each stage. |

---

---

## Quick start


### 1. Provide a model

Place any GGUF model in `models/`:

```text
starfish/
└── models/
    └── model.gguf
```

On startup, Starfish launches the local model server automatically. To run the server yourself, leave `models/` empty and see [Configuration](#configuration).

### 2. Run

```bash
./CnR STARFISH.cnr
```

The service listens on `http://127.0.0.1:7070`.

### 3. Submit tasks

```bash
# Short answer
curl -X POST localhost:7070/tasks \
  -H 'Content-Type: application/json' \
  -d '{"task":"ask:what is the water vascular system of a sea star?"}'
# {"taskId":1,"status":"queued"}

# Long, reviewed answer written in parts
curl -X POST localhost:7070/tasks \
  -H 'Content-Type: application/json' \
  -d '{"task":"gen:explain how sea stars regenerate lost arms"}'

# Fetch the result and the reviewer events
curl localhost:7070/tasks/2
```

To follow a long generation as it runs:

```bash
tail -f starfish.log
curl localhost:7070/status      # "progress": "part 2/4: reviewer checking ..."
```

---

## Architecture

### Modules

Each source file implements one component. Module names are Portuguese anatomical terms.

| File | Anatomical analogue | Role in Starfish |
|---|---|---|
| `STARFISH.cnr` | Whole organism | Entry point: HTTP server, FIFO task queue, background worker thread. |
| `MADREPORITO.cnr` | Madreporite (sieve plate) | Input/output filter. Sanitizes and size-limits data, parses `tool:argument`, and provides the text toolbox (`indexOf`, `split`, `trim`, `substring`, ...) that the language lacks natively. |
| `HEMALRING.cnr` | Hemal ring | The ACC (*Central Circular Ring*), the coordinator. Selects arms, runs reviews, assigns penalties and credit, regenerates arms, forges skills, grants XP. |
| `RAY.cnr` | Rays (arms) | Defines the `Ray` struct and the five roles. Each arm holds a worklist, learned weights, pain, load, strikes, credits and personality traits. |
| `CANAL.cnr` | Radial canal | The only bridge from the ring to an arm. Enforces that an arm runs only tools on its own worklist. |
| `AMBULACRO.cnr` | Ambulacral system (tube feet) | The tool layer: file read/write, HTTP, local model calls, skill and memory tools, and the system prompt for each role. |
| `INTERRADII.cnr` | Interradii | Environment: logging, workspace paths, live progress, and the system's pace, which increases as work accumulates. |
| `STIMULI.cnr` | N/A | Deterministic quality checks that require no model. |
| `ECOSSYSTEM.cnr` | N/A | Long-term memory of lessons. |
| `SPECIFICITIES.cnr` | N/A | The self-generated skill library. |
| `DARWINISM.cnr` | Growth | XP, levels, and every budget that scales with them. |

### Component overview

The components fit together as follows.

A client sends `POST /tasks` to the HTTP server in `STARFISH.cnr`, which places the task on a FIFO queue. A single worker thread takes tasks from the queue one at a time and hands each to `MADREPORITO.cnr`, which sanitizes the input, enforces size limits and parses it into a tool and an argument.

The parsed task goes to the ACC in `HEMALRING.cnr`. The ACC is the only component that decides which arm does what. It holds each arm's state (learned weights, load, pain) and consults four support modules: `STIMULI.cnr` for deterministic checks, `ECOSSYSTEM.cnr` for lessons, `SPECIFICITIES.cnr` for skills and `DARWINISM.cnr` for XP, levels and budgets.

When the ACC needs an arm to run a tool, the call goes through `CANAL.cnr`, which verifies that the tool is on that arm's worklist. `AMBULACRO.cnr` then implements the tool: it builds the role prompt, calls the local GGUF model, or reads and writes inside `starfish_workspace/`.

### Task dispatch

A task enters as a single line, `tool:argument`. After filtering, the ring selects the most suitable living arm, the call passes through the canal, and the outcome updates that arm's state.

The steps are:

1. **Filter.** The task line is sanitized and checked against the input size limit.
2. **Parse.** If the line contains no colon, it is treated as `echo:<text>`. Otherwise it is split into a tool and an argument.
3. **Score.** Every living arm that can run the tool receives a score: its learned weight for that tool, minus its recent load and pain, plus random noise scaled by its boldness.
4. **Select.** The arm with the highest score is chosen.
5. **Verify.** The canal checks that the tool is on the chosen arm's worklist. If it is not, the call is refused. Under normal scheduling this cannot happen, because only eligible arms are scored. The check is a safety net.
6. **Execute.** `AMBULACRO.cnr` runs the tool.
7. **Update.** On success, the arm's weight for the tool increases and its pain decays. On failure, pain is added and the weight decreases. A fraction of the weight update is then propagated to the other arms that can run the same tool.
8. **Record.** The result and the events produced during the task are stored and become available through `GET /tasks/:id`.

---

## Arms

The ring starts with five arms and grows to nine. Each role owns a distinct set of tools, and an arm cannot run a tool outside its role.

| Role | Tools | Responsibility |
|---|---|---|
| Executor | `read`, `write`, `http`, `echo`, `ask`, `gen`, agent step | Reads, writes, queries the model, and writes the text of long answers. |
| Reviewer | `review` | Checks each part against the goal and the rules. Can stop a response, name the error and assign negative points. |
| Archivist | `skill`, `mem`, `compact` | Maintains memory: records lessons, compacts them on overflow, lists skills. |
| Blacksmith | `forge` | Converts repeated errors into short reusable skills. |
| Planner | `plan` | Breaks a goal into an ordered outline of 3 to 8 topics. Unlocks at level 2. |

### Per-arm state

Each `Ray` carries its own state:

- **`memory`**: a learned weight per tool it can operate, initialized at 0.5.
- **`singularities`** (personality): *boldness* (exploration rate), *retreat* (sensitivity to negative signals), *plasticity* (learning rate).
- **`pain`**: accumulated negative signal, decays on success.
- **`load`**: recent workload. Heavily used arms are deprioritized by the scheduler.
- **`strikes` / `credits`**: lifetime penalties and rewards issued by reviewers.
- **`generation`**: number of times the arm's slot has been replaced.
- **`briefing`**: context packet delivered at creation.

### Arm selection

An arm is chosen by its learned weight for the requested tool, minus its recent load and pain, plus random noise scaled by its boldness. The noise keeps the ring exploring instead of converging on a single arm.

### Knowledge sharing

When an arm updates its weight for a tool, a fraction of that update propagates to every other arm that can operate the same tool.

---

## Long-form generation and review

The `gen:` tool produces long answers in parts. Every part must pass inspection before it is added to the final text.

A `gen:` task runs as follows.

1. **Plan.** From level 2, the planner arm outlines the goal as 3 to 8 ordered topics.
2. **Write.** An executor arm writes the next part. Its prompt contains the plan, the rules, the relevant lessons and the relevant skills.
3. **Deterministic checks.** The part passes through the indicators described [below](#indicators). If any check fails, the part goes straight to error handling and no reviewer call is made.
4. **Review.** If the checks pass, a reviewer arm inspects the part against the goal and answers with a verdict: `OK` or `ERROR` with a severity, a description and a fix.
5. **Accept or stop.** An `OK` verdict adds the part to the answer. An `ERROR` verdict, or a failed indicator, stops the part and discards it.
6. **Error handling.** The executor is penalized and the archivist records a lesson. If the severity is 3, the responsible arm is also replaced immediately, with the lesson as its briefing.
7. **Retry.** If the retry budget for the current level allows it, the part is regenerated with the correction in the prompt and goes through steps 3 to 5 again. If retries are exhausted, the part is kept and a written caveat is appended to the answer.
8. **Continue or finish.** The loop repeats from step 2 until a part emits the `[FIM]` marker or the part limit for the current level is reached, and the parts are then assembled into the answer.
9. **Skill forging.** If the task produced repeated errors, the blacksmith arm forges a skill from them.

### Handling a reviewer finding

1. The response is stopped at that point and the faulty part is discarded.
2. The finding is recorded in the task's `events`.
3. The executor receives negative points: pain, a lower tool weight and a strike. Sufficient pain removes the arm and triggers replacement.
4. The archivist writes a lesson to long-term memory, which applies to the retry.
5. The part is regenerated with the correction injected into the prompt.

A severity-3 error (fabricated or unusable output) additionally replaces the responsible arm immediately, with the lesson as its briefing.

If retries are exhausted, the part is kept and a written caveat is appended to the answer. Unresolved problems are never concealed.

### Reviewer cross-checking

From level 3 the ring has two reviewers. One must confirm the other's accusation before it counts, and a false alarm penalizes the arm that raised it.

### Part stitching

Parts are written under a token budget, so a part may end mid-sentence or mid-line of code. In that case the next part is told the text was cut and continues exactly where it stopped. A part ends the answer by emitting an explicit `[FIM]` marker.

---

## Indicators

Small models are unreliable at reviewing their own output. Before the reviewer arm spends a model call, every part of a `gen:` answer and every `ask:` answer passes through deterministic checks.

| Indicator | Detects |
|---|---|
| `repeticao` (repetition) | Sentences of 50 bytes or more that already appeared earlier in the text. |
| `laco` (loop) | The same 4-word sequence repeating. |
| `diversidade` (diversity) | Low vocabulary diversity, indicating text that is stalling. |
| `linhas-iguais` (identical lines) | Three or more identical consecutive lines. |
| `marcador` (marker leak) | Prompt or reasoning leaking into output (`<think>`, role tags, verdict markers, ...). |
| `alfabeto` (alphabet) | Characters from a script that does not belong in the request. |
| `desvio` (drift) | A first part that never mentions the requested subject. |
| `codigo` (code) | Closed code blocks with unbalanced `()`, `{}`, `[]`, or malformed declarations. |
| `curta` (too short) | A part that is nearly empty. |

A failed check stops the part, penalizes the arm and triggers a regeneration with the correction, without a reviewer call. Per-part metrics are published in `/status` and in the log. Thresholds are defined at the top of each function in `STIMULI.cnr`.

---

## Memory and skills

### Lessons (`ECOSSYSTEM.cnr`)

Every confirmed error becomes a one-line lesson of the form *what went wrong, how to fix it*. Lessons are persisted in `starfish_workspace/context.txt` and recalled by a relevance score:

```text
relevance = shared words with the goal x 10 + recency (up to 3) + manual rule bonus (+5)
```

The highest-scoring lessons that fit the current budget are injected into every prompt. When the store exceeds the budget for the current level, the archivist compacts it. If compaction returns empty output, nothing is deleted.

### Skills (`SPECIFICITIES.cnr`)

When errors repeat, the blacksmith forges a skill: a short, imperative, reusable rule in the form `name | instruction`.

- Every skill that fits the budget is injected into each `ask:` and `gen:`, most relevant first. A task's `events` begins with `skills in use: a, b, c`.
- Each skill has a score. An approved answer raises it. A content error flagged by the reviewer lowers it, at most once per task. Model loops and repetitions are never attributed to a skill.
- A skill that degrades results is discarded, and the blacksmith that forged it is penalized.
- Skills persist in `starfish_workspace/skills.txt`. The skill cap grows with level, from 6 to 24.

Memory and skills can also be managed manually:

```text
skill:list                       list learned skills
skill:new <topic>                ask the blacksmith to forge a skill
skill:<name>|<task>              run a task through a specific skill (with review)
mem:list | mem:count             inspect lessons
mem:add <lesson>                 add a manual rule (receives a relevance bonus)
mem:find <word>                  recall lessons by keyword
```

---

## Progression

Starfish earns XP for completed tasks, approved parts, fixed errors, forged skills and memory compaction. XP unlocks levels, and every budget in the system scales with the level.

| Level | Stage | XP | Arms | Tokens / part | Max parts | Agent steps | Regens / part | Max skills |
|:---:|---|---:|:---:|---:|:---:|:---:|:---:|:---:|
| 1 | Larva | 0 | 5 | 1,024 | 4 | 4 | 1 | 6 |
| 2 | Juvenile | 12 | 6 | 1,536 | 6 | 6 | 2 | 10 |
| 3 | Young | 40 | 7 | 2,048 | 8 | 8 | 2 | 14 |
| 4 | Adult | 100 | 8 | 3,072 | 10 | 10 | 3 | 18 |
| 5 | Elder | 220 | 9 | 4,096 | 12 | 12 | 3 | 24 |

New arms are added at fixed levels: a planner at level 2, a second reviewer at level 3, a third executor at level 4, and a second archivist at level 5.

All text budgets (injected context, text fed back to continue a part, agent history) are fractions of the model's context window and cannot exceed it. Progress is saved to `starfish_workspace/estado.txt` and persists across restarts.

---

## Arm lifecycle

Negative signal has direct consequences. Failed actions and reviewer penalties add pain and lower the arm's weight for the tool involved. Successes cause pain to decay. Past its threshold, the arm is removed and a replacement is created in the same ring slot.

The replacement is not immediate. It happens after a delay of about 5 ticks of roughly 100 ms each, and the new arm starts a new generation in the vacated slot.

A replacement arm is initialized as follows:

- **Role**: chosen by which role the ring lacks most, plus unmet demand, with some bias toward keeping the current role.
- **Weights**: a fitness-weighted average of living arms with a success rate of at least 40 %, plus mutation.
- **Personality**: inherited from the best arm of the same role, plus mutation.
- **Briefing**: a new executor receives the most recent lessons.

---

## Tools and task syntax

Every task is a single line: `tool:argument`. A line with no colon is treated as `echo`.

| Task | Description |
|---|---|
| `ask:<question>` | A single call to the local model with skills and lessons injected, deterministic checks applied, and one corrected retry on failure. Suited to single-file programs and short answers. |
| `gen:<goal>` | A long answer written in parts, planned and reviewed by arms. |
| `agent:<goal>` | A multi-step agent loop. The model replies with `TOOL tool:arg` or `FINAL answer`. Step count scales with level. The final answer is reviewed once and corrected if needed. |
| `skill:...` / `mem:...` | Manage skills and long-term memory. See [Memory and skills](#memory-and-skills). |
| `read:<file>` | Read a file from the workspace. |
| `write:<text>` | Append a note to the workspace. |
| `http:<url>` | HTTP `GET`, localhost only. |
| `echo:<text>` | Return the text. |

### Limits

Input is capped at 4,000 bytes and output at 60,000 bytes. A direct `ask:` can produce up to 2,048 tokens.

---

## HTTP API

| Method | Route | Description |
|---|---|---|
| `POST` | `/tasks` | Queue a task. Body: `{"task": "gen:explain ..."}`. Response: `202 {"taskId": 1, "status": "queued"}`. |
| `GET` | `/tasks/:id` | Returns `status` (`queued`, `running`, `done`, `failed`), `result`, the `ray` and `tool` used, and `events`. |
| `GET` | `/status` | Level, XP, arms, queue depth, current task and live `progress`. |
| `GET` | `/skills` | Skills the system has generated. |
| `GET` | `/context` | Lessons archived so far. |

The `events` field of a task is a chronological log of reviewer stops, penalties, regenerations, arm replacements, skills in use and level-ups.

If a task fails internally, it is marked `failed` with the message in `result` and `ERRO INTERNO` in the log. It never remains in `running`.

---

## Configuration

Settings are defined at the top of `AMBULACRO.cnr`.

| Setting | Default | Description |
|---|---|---|
| `ambModelPath` | `models/model.gguf` | Path to the local model. If the file exists, Starfish starts it automatically. |
| `ambCtxTokens` | `16384` | The model's context window. Every budget in the system derives from this value. |
| `ambLlamaArgs` | `-c 16384` | Additional flags for the model server. |
| `ambLlamaMaxTokens` | `2048` | Token limit for a direct `ask:`. |

> [!IMPORTANT]
> `ambCtxTokens` and the `-c` flag must match. Use `32768` if memory allows, or `8192` if it is constrained.

If no model file is present, Starfish connects to a model server already running at `http://127.0.0.1:8080`. The server binary and URL can be overridden with environment variables, documented in the header of `AMBULACRO.cnr`. If neither is available, Starfish still starts, and only the model-backed tools fail.

Small models are prone to repetition loops. Adding `--repeat-penalty 1.1 --dry-multiplier 0.8` to the server flags reduces them substantially.

> [!NOTE]
> The role prompts and the `alfabeto` indicator are tuned for Portuguese. They are plain strings at the top of `AMBULACRO.cnr` and `STIMULI.cnr` and can be translated directly.

---

## Security model

> [!WARNING]
> Starfish has file and HTTP tools. Do not bind it to `0.0.0.0` without adding authentication.

- The server binds to `127.0.0.1` only.
- File reads are confined to `starfish_workspace/`. Paths containing `..` are rejected.
- Writes only append to a notes file inside the workspace.
- HTTP tools reach only `localhost` and `127.0.0.1`.
- Arms cannot run tools outside their role's worklist.

---

## Project layout

```text
starfish/
├── STARFISH.cnr          # entry point: HTTP server, queue, worker
├── MADREPORITO.cnr       # input/output filter and text toolbox
├── HEMALRING.cnr         # ACC: coordinator
├── RAY.cnr               # arms: struct, roles, creation
├── CANAL.cnr             # ring-to-arm bridge (worklist enforcement)
├── AMBULACRO.cnr         # tools and role prompts
├── INTERRADII.cnr        # logs, paths, progress, pace
├── STIMULI.cnr           # deterministic quality checks
├── ECOSSYSTEM.cnr        # long-term memory of lessons
├── SPECIFICITIES.cnr     # self-generated skill library
├── DARWINISM.cnr         # XP, levels, budgets
├── models/               # place .gguf files here
├── starfish_workspace/   # sandbox and persistent state (created at runtime)
│   ├── context.txt       #   lessons
│   ├── skills.txt        #   skills and scores
│   ├── estado.txt        #   XP and level
│   └── notes.txt         #   output of write:

```

---

## Why CnR

Starfish is written entirely in CnR. The ring, arms, reviewer loop, scheduler, memory, skill library, HTTP server and task queue are all CnR source.

Language features used throughout the project:

- **Declarative structure**: `Sector`, `Struct`, `Bundle` and `Gather` define the modules, and `Shard` lays out the ring of arms.
- **Pipelines**: a task's lifecycle is a `Nodes` pipeline (`Sense`, `Decide`, `Act`) with built-in retry on failure.
- **Servers and threads**: the HTTP server and the worker thread are a few declarative lines.
- **Local-model bridge**: the interpreter exposes the calls needed to start and query a local model.

CnR has no standard string library, so `MADREPORITO.cnr` implements one in pure CnR.

Running Starfish requires the CnR interpreter, a single C++17 source file (`CnR.cpp`) built with `-pthread`.
