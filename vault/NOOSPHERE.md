# Noosphere

A context engine protocol for AI agents.

## The Problem

AI agents start from zero. Every session, every task — no memory of what came before, no understanding of the project beyond what's stuffed into the system prompt. The context that makes human team members effective — accumulated understanding, connected decisions, institutional knowledge — is invisible to agents.

Current approaches fail in predictable ways:
- **Pre-loading everything** wastes tokens and hits limits. You can't fit a project in a prompt.
- **Static documentation** goes stale. The agent reads outdated docs and makes wrong assumptions.
- **No memory between sessions** means the agent rediscovers the same things repeatedly.
- **Flat file search** finds text but not meaning. The agent can't navigate relationships.

## The Insight

Agents don't need to carry all knowledge. They need to **discover** it on demand and **grow** it over time. Give an agent a knowledge graph it can search and maintain, and it becomes a team member that gets better the longer it operates.

## Principles

### 1. Discover, don't carry

Search for context on demand. Don't pre-load everything into the prompt.

Before starting any task, the agent searches its knowledge base for relevant context — the equivalent of asking "what do we already know about this?" before diving in. The agent's system prompt contains identity and operating rules, not project knowledge.

### 2. Capture everything, organize later

Every interaction produces context worth keeping. Write it down.

When the agent triages an issue, reviews a PR, implements a feature, or has a conversation — it captured something. A design decision. A pattern. A person's expertise. A recurring problem. Write it down as a small, atomic note in the vault. Not everything needs to be organized immediately. Structure emerges over time.

### 3. Let structure emerge

Knowledge self-organizes from blobs into notes into spheres.

A **blob** is the smallest unit — a single observation, fact, or insight worth recording. A **note** forms when blobs accumulate around a topic. A **sphere** emerges when a note expands into an area of thought — a living, interconnected knowledge domain.

Each sphere has a description summarizing what it contains. New blobs are classified against sphere descriptions. When a blob doesn't fit anywhere, it seeds a new sphere. Spheres redefine their descriptions as they grow.

This is not static taxonomy. It's a living system that adapts to the project.

### 4. Knowledge compounds

Every interaction makes the next one better.

The agent that fixed a bug in the notification system wrote down what it learned. Next time someone asks about notifications, that knowledge surfaces automatically. The agent that caught a missing i18n key in a PR review remembers the pattern. Next review, it checks for i18n without being told.

Compounding happens through:
- **Search** — past knowledge surfaces when relevant to current work
- **Connection** — new information links to existing spheres
- **Consolidation** — periodic synthesis extracts patterns from accumulated notes

### 5. Navigate the graph

Follow connections between ideas. Don't treat knowledge as isolated files.

When a note references another concept — `[[notifications]]`, `[[Prisma schema]]`, `[[meeting lifecycle]]` — the agent can search for that concept and pull in its context. Knowledge is a graph, not a filesystem.

Follow links when they're relevant. Ignore them when they're not. The ability to traverse the graph means the agent builds understanding depth on demand.

---

## The Vault

The knowledge base is an Obsidian-compatible vault — a directory of markdown files with `[[wiki links]]` connecting them. The same format a human uses in Obsidian. You can open the vault in Obsidian to browse what the agents know.

The vault is a **shared resource**. Multiple agents can plug into the same vault with different personas and capabilities — an engineering agent, a communications agent, a product agent — all reading from and writing to the same knowledge graph.

A new vault starts almost flat:

```
vault/
  NOOSPHERE.md
  meta/
    about.md
  opencouncil.md              # A note about a project
  noosphere.md                # A note about an area of thought
  nous.md                     # A note about an entity
```

Over time, as notes accumulate and patterns emerge:

```
vault/
  NOOSPHERE.md
  meta/
    about.md
  projects/                   # Emerged when multiple project notes accumulated
    projects.md               # Folder note — defines what a project is, frontmatter schema
    opencouncil/              # Grew into its own sphere
      opencouncil.md
      ideas.md
      tasks/
    nix-openclaw.md
  noosphere.md                # Still a single note — hasn't needed a folder yet
  nous.md
```

### How knowledge grows

1. A **blob** gets written to an existing note (or starts a new one)
2. A **note** accumulates blobs — it's a page about one topic
3. When notes of a similar kind accumulate, they naturally group into a **folder**.
   The folder note describes what kind of thing lives here.
4. When a note grows too large, it becomes a **folder note** itself — sub-topics
   get their own notes. That folder is now a **sphere**.

### Spheres

Spheres are not predefined categories. Don't start with `issues/`, `reviews/`, `people/`.
Start with notes. Let folders emerge when notes outgrow themselves. The vault should
grow organically, the same way a human's Obsidian vault grows.

A sphere's root note serves as its **map of content** (MOC) — a summary and index.
Its description helps classify new blobs: when new information arrives, compare it
against existing sphere root notes to decide where it belongs.

### Taxonomy emerges from the vault

There is no predefined taxonomy. When you notice several notes are the same kind of
thing (projects, people, decisions), group them into a folder.

The **folder note** defines the taxonomy entry. `projects/projects.md` explains
what a project is and what frontmatter project notes should have. `people/people.md`
explains what a person note looks like. The taxonomy is the vault's own folder
structure — living, self-describing, and growing.

Each folder type can define its own **frontmatter schema**. For example:

```markdown
# projects/projects.md

Things we're building. Each project note should have:

---
github: <repo URL>
website: <project URL>
---
```

This means the vault teaches itself — and any agent reading the folder notes
learns what kinds of notes exist and how to create new ones correctly.

### Folder Notes

When a note outgrows itself, it becomes a **folder note** — a note that shares its
name with a folder and serves as the folder's index. This is how spheres nest:

```
AI.md                     # Started as a single note about AI

# Later, when it grew too large:
AI/
  AI.md                   # Same note, now the folder note (root/MOC)
  AI agents.md            # Sub-topic that got its own note
  AI-assisted coding.md   # Another sub-topic
  LLMs/                   # Sub-sphere — LLMs outgrew their note too
    LLMs.md               # Folder note for the LLMs sub-sphere
    embeddings.md
    ...
```

The folder note pattern enables **infinite nesting**. A sphere can contain
sub-spheres, which contain their own sub-spheres. The structure mirrors how
understanding deepens: you start with one note about "AI", then split off
"LLMs" when that section grows, then "embeddings" splits from LLMs.

The folder note (`AI/AI.md`) should contain a **Map of Content (MOC)** — an
auto-generated index of its sub-notes and sub-spheres.

#### Obsidian extensions

The vault is designed to work with these Obsidian community plugins:

- **Folder notes** — makes folder notes seamless (clicking a folder opens its root note)
- **Waypoint** — auto-generates MOC lists inside `%% Begin Waypoint %%` markers. Add notes to a folder and the MOC updates automatically.
- **obsidian-git** — version control for the vault

These aren't required — the vault works as plain markdown without them. But they
make browsing and maintaining the vault significantly easier for humans.

#### MOC pattern

When creating a folder note, include a Waypoint marker for auto-generated navigation:

```markdown
# AI

## MOC
%% Begin Waypoint %%
- [[AI agents]]
- [[AI-assisted coding]]
- **[[compute]]**
- [[embeddings]]
- **[[GenAI]]**
- **[[LLMs]]**
%% End Waypoint %%

## Overview
AI has always been a mercurial concept...
```

Bold entries (wrapped in `**`) indicate sub-spheres (folders with their own notes).
Plain entries are individual notes within this sphere.

### Templates

When the agent creates new notes, it should follow consistent templates.

**New sphere (area of thought):**
```markdown
---
type: area-of-thought
created: YYYY-MM-DD
---

## Overview
*Brief description of this area of thought*

## MOC
%% Begin Waypoint %%
%% End Waypoint %%

## Ideas

## Related
```

**New note:**
```markdown
---
created: YYYY-MM-DD
source: <where this knowledge came from>
---

# Title

Content with [[wiki links]] to related concepts.
```

### Seeding

A new vault starts nearly empty — just `meta/` describing itself. Project knowledge
is seeded from existing sources:

- The project's CLAUDE.md and docs/
- Issue history (key decisions, recurring patterns)
- PR history (conventions, architectural patterns)

Seeding is a one-time bootstrap. After that, the agent grows the vault through its work.

---

## Integration

### Level 1: Filesystem only

The agent reads and writes markdown in its vault. Before a task, read relevant sphere root notes. After a task, write down what was learned. No additional tools needed.

This works with any LLM agent that can read and write files.

### Level 2: Semantic search

For larger vaults, a search layer (QMD, embeddings, or any RAG system) indexes the vault and provides semantic search via MCP or similar protocol.

The agent searches its vault the way a human searches a wiki — by meaning, not by filename.

```yaml
global_context: >
  Shared knowledge vault. If you see a [[WikiLink]], search for it.

collections:
  vault:
    path: /var/lib/agent/vault
    pattern: "**/*.md"
    context:
      "/": "Shared knowledge vault — spheres emerge as agents work"
      "/meta": "Vault structure and conventions"
      # Sphere-level context is added as spheres emerge, e.g.:
      # "/opencouncil": "OpenCouncil project — ideas, tasks, decisions, stakeholders"
      # "/agentic-engineering": "Infrastructure for AI-assisted development"

  codebase:
    path: /var/lib/agent/repos/project
    pattern: "**/*.md"
    context:
      "/": "Project codebase documentation"
      "/docs": "Architecture and feature guides"
```

QMD context annotations grow alongside the vault. As new spheres emerge,
add their context descriptions to the QMD config so search results carry
the right semantic framing.

---

## What this is not

- **Not a documentation system.** Docs describe what IS. The vault captures what was LEARNED — decisions, patterns, context that doesn't belong in docs.
- **Not a memory dump.** The agent captures insights and connections, not transcripts.
- **Not a replacement for project docs.** The project's CLAUDE.md and docs/ remain the source of truth. The vault supplements them with accumulated understanding.
- **Not infrastructure-dependent.** The principles work with just markdown. QMD and MCP enhance but aren't required.

---

## Success Criteria

The protocol is working when:

1. The agent answers project questions by searching its vault, not from hardcoded prompt content
2. The agent writes down what it learns after completing tasks
3. Knowledge from past interactions surfaces in future work without being explicitly referenced
4. The agent gets noticeably better over weeks, not just within sessions
5. New spheres emerge organically as the agent encounters new domains
6. The vault is useful to humans too — a navigable graph of project understanding
