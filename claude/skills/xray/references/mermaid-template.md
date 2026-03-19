# Mermaid Graph Template

Template for generating role-grouped dependency flowcharts. The scout writes the
Mermaid source to `.context/xrays/{slug}-graph.md`.

## Structure

```mermaid
flowchart TD

  %% Traffic light styles
  classDef green fill:#2d6a4f,stroke:#1b4332,color:#d8f3dc
  classDef yellow fill:#e9c46a,stroke:#f4a261,color:#264653
  classDef red fill:#e63946,stroke:#d62828,color:#f1faee
  classDef unverified fill:#6c757d,stroke:#495057,color:#f8f9fa
  classDef hub fill:#7209b7,stroke:#560bad,color:#f8f9fa
  classDef util fill:#4361ee,stroke:#3a0ca3,color:#f8f9fa
  classDef terminal fill:#adb5bd,stroke:#6c757d,color:#343a40,stroke-dasharray:5 5

  %% Entry points (nothing imports these)
  subgraph entry ["Entry Points"]
    {nodeId}["{symbolName}\nfanIn:0 fanOut:{N}"]
  end

  %% Hubs (high traffic both directions)
  subgraph hubs ["Hubs"]
    {nodeId}["{symbolName}\nfanIn:{N} fanOut:{M}"]:::hub
  end

  %% Domain (business logic)
  subgraph domain ["Domain"]
    {nodeId}["{symbolName}\nfanIn:{N} fanOut:{M}"]
  end

  %% Utilities (widely imported, few deps)
  subgraph utils ["Utilities"]
    {nodeId}["{symbolName}\nfanIn:{N} fanOut:{M}"]:::util
  end

  %% Leaves (import nothing internal)
  subgraph leaves ["Leaves"]
    {nodeId}["{symbolName}\nfanIn:{N} fanOut:0"]
  end

  %% Terminal (external — dashed border)
  subgraph terminals ["Terminal (external)"]
    {nodeId}["{symbolName}"]:::terminal
  end

  %% Edges
  {fromId} --> {toId}
  {fromId} -.-> {toId}  %% call edges use dotted lines

  %% Apply exactly ONE status class per node (regenerate on each verdict)
  %% Hub/util/terminal role classes are set inline (:::hub, :::util, :::terminal)
  %% Traffic light class overrides the role class after a verdict is confirmed:
  class {greenNodeId} green
  class {yellowNodeId} yellow
  class {redNodeId} red
  %% Unverified nodes keep their role class (hub/util) or get explicit unverified:
  class {unverifiedNodeId} unverified
```

## Conventions

- **Solid arrows** (`-->`) = import edges
- **Dotted arrows** (`-.->`) = call edges
- **Node labels** include `fanIn`/`fanOut` counts
- **Subgraph grouping** by role — entry, hubs, domain, utils, leaves, terminals
- **One class per node**: Each node gets exactly one class at generation time.
  Regenerate the full Mermaid source on each `map` command rather than appending.
- **Role classes** (`:::hub`, `:::util`, `:::terminal`) are applied inline in the
  node definition. When a traffic light verdict is confirmed, the traffic light
  class replaces the role class.
- **Terminal nodes** always keep dashed stroke (`:::terminal`), even after auto-green
- **Hub nodes** start purple (`:::hub`) until a verdict overrides to green/yellow/red

## Ego-centric View (`map <node>`)

For `map <node>`, generate a subset graph:
- The focal node (bold border)
- All nodes 1 hop away (direct importers + direct dependencies)
- Edges between these nodes only
- Same classDef styling

```mermaid
flowchart TD
  classDef focal fill:#fb8500,stroke:#e76f51,color:#f1faee,stroke-width:3px
  %% ... same classDefs as above ...

  {focalNode}["{symbolName}"]:::focal
  {importerId} --> {focalNode}
  {focalNode} --> {depId}
```
