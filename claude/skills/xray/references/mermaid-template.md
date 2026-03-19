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
    {nodeId}["{symbolName}\nfanIn:{N} fanOut:{M}"]
  end

  %% Domain (business logic)
  subgraph domain ["Domain"]
    {nodeId}["{symbolName}\nfanIn:{N} fanOut:{M}"]
  end

  %% Utilities (widely imported, few deps)
  subgraph utils ["Utilities"]
    {nodeId}["{symbolName}\nfanIn:{N} fanOut:{M}"]
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

  %% Apply traffic light classes after verdicts
  class {nodeId} green
  class {nodeId} yellow
  class {nodeId} red
  class {nodeId} unverified
```

## Conventions

- **Solid arrows** (`-->`) = import edges
- **Dotted arrows** (`-.->`) = call edges
- **Node labels** include `fanIn`/`fanOut` counts
- **Subgraph grouping** by role — entry, hubs, domain, utils, leaves, terminals
- **Traffic light classDefs** applied after each verdict during the DFS loop
- **Terminal nodes** always get dashed stroke, regardless of traffic light
- **Hub nodes** get purple fill to stand out as high-traffic intersections

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
