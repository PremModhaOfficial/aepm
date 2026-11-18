//! Pure dependency-forest view over the prefetch pending set.
//!
//! The data is a DAG; this module turns it into the forest the TUI prints. It
//! is read-only and pure: no I/O, no clock, no collector. Roots are pending
//! packages with no pending dependent. Children are stored in
//! artifact-rank/name order. The frame prints bottom-up like nom, so the
//! renderer walks the stored children in reverse and puts each root last in
//! its own subtree.
//!
//! A package is printed once. When several pending packages depend on it, the
//! first parent in the deterministic traversal keeps it and later edges do not
//! create a second subtree. A dependency outside the pending set is a
//! display-only `Unknown` leaf: it is marked `?` and never expanded.
//!
//! A cycle component with no incoming root cannot be drawn as a forest. That
//! is a deterministic error, not an invented root.

use std::collections::{BTreeMap, BTreeSet};
use std::time::SystemTime;

use crate::frontier::{Edge, EdgeKind};
use crate::report::{ArtifactState, PackageView, Repo};

pub type RowId = usize;

// One drawn frame must build the forest once. `FramePlan` measures the window
// from a `Tree` and `draw_with` draws that same tree, so a second build is the
// duplicate this counter exists to catch. Thread-local and read as a delta
// around the caller's own frame, so the count is deterministic under any load.
#[cfg(test)]
thread_local! {
    static TREE_BUILDS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
fn note_tree_build() {
    TREE_BUILDS.with(|builds| builds.set(builds.get().saturating_add(1)));
}

/// How many forests this thread has built so far.
#[cfg(test)]
pub fn tree_builds() -> u64 {
    TREE_BUILDS.with(std::cell::Cell::get)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeRowKind {
    Package,
    UnknownDependency,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeRow {
    pub id: RowId,
    pub parent: Option<RowId>,
    pub children: Vec<RowId>,
    pub depth: usize,
    pub kind: TreeRowKind,
    pub name: String,
    pub label: String,
    pub repo: Repo,
    pub artifact: Option<ArtifactState>,
    pub artifact_at: Option<SystemTime>,
    /// The pending version this row will install, when known. The live cache
    /// monitor compares it so a stale left-over cannot finish the row.
    pub available: Option<String>,
    pub detail: Option<String>,
    pub size: Option<u64>,
}

/// The forest could not be built. The package list is deterministic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TreeError {
    Cycle { packages: Vec<String> },
}

impl std::fmt::Display for TreeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cycle { packages } => {
                write!(
                    formatter,
                    "dependency cycle has no root: {}",
                    packages.join(", ")
                )
            }
        }
    }
}

impl std::error::Error for TreeError {}

/// One deterministic forest of the pending set.
///
/// `rows` is in creation (pre-order) order. `roots` holds the top-level
/// packages in artifact-rank/name order; none of them has a parent. Use
/// [`Tree::display_rows`] for the bottom-up frame order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tree {
    pub rows: Vec<TreeRow>,
    pub roots: Vec<RowId>,
    /// The required dependency edges of the pending graph, dependency to
    /// dependent. Display-only unknown dependencies produce no edge. This is
    /// the input the frontier seed needs, so the live view does not re-resolve
    /// dependencies on its own.
    pub edges: Vec<Edge>,
}

impl Tree {
    /// Build the forest from the pending packages. The input is not mutated
    /// and duplicate package names collapse to the first occurrence.
    ///
    /// Any pending package left without a root is a cycle component; the
    /// build fails instead of attaching it to an invented node.
    pub fn build(packages: &[PackageView]) -> Result<Self, TreeError> {
        #[cfg(test)]
        note_tree_build();
        let mut rows = Vec::with_capacity(packages.len());
        let mut unique: Vec<&PackageView> = Vec::with_capacity(packages.len());
        let mut index: BTreeMap<&str, usize> = BTreeMap::new();
        for package in packages {
            if index.contains_key(package.name.as_str()) {
                continue;
            }
            index.insert(package.name.as_str(), unique.len());
            unique.push(package);
        }

        let resolved: Vec<Vec<Dependency>> = unique
            .iter()
            .map(|package| resolve(package, &index, &unique))
            .collect();

        let mut edges = Vec::new();
        for (owner, dependencies) in resolved.iter().enumerate() {
            for dependency in dependencies {
                if let Some(target) = dependency.pending {
                    edges.push(Edge::new(
                        unique[target].name.clone(),
                        unique[owner].name.clone(),
                        EdgeKind::Runtime,
                        true,
                    ));
                }
            }
        }
        edges.sort_by(|left, right| {
            left.dependent
                .cmp(&right.dependent)
                .then_with(|| left.dependency.cmp(&right.dependency))
        });

        let mut has_dependent = vec![false; unique.len()];
        for (owner, dependencies) in resolved.iter().enumerate() {
            for dependency in dependencies {
                if let Some(target) = dependency.pending {
                    if target != owner {
                        has_dependent[target] = true;
                    }
                }
            }
        }

        let order = package_order(&unique);
        let mut placed = vec![false; unique.len()];
        let mut unknown = BTreeSet::new();
        let mut roots = Vec::new();

        for package in order.iter().copied() {
            if has_dependent[package] {
                continue;
            }
            placed[package] = true;
            let row = attach_package(&mut rows, None, unique[package], 0);
            roots.push(row);
            expand(
                &mut rows,
                row,
                package,
                &unique,
                &resolved,
                &mut placed,
                &mut unknown,
            );
        }

        let unplaced: Vec<String> = order
            .iter()
            .copied()
            .filter(|package| !placed[*package])
            .map(|package| unique[package].name.clone())
            .collect();
        if !unplaced.is_empty() {
            return Err(TreeError::Cycle { packages: unplaced });
        }

        sort_children(&mut rows);
        Ok(Self { rows, roots, edges })
    }

    /// Bottom-up display order: every child subtree above its parent, each
    /// root last in its own subtree. Nom also prints siblings in reverse
    /// stored order and roots in reverse stored order, so the last child is
    /// the top row and the first child sits next to the parent.
    pub fn display_rows(&self) -> Vec<&TreeRow> {
        let mut out = Vec::with_capacity(self.rows.len());
        for root in self.roots.iter().rev() {
            let mut stack = vec![(*root, false)];
            while let Some((id, expanded)) = stack.pop() {
                if expanded {
                    out.push(&self.rows[id]);
                    continue;
                }
                stack.push((id, true));
                for child in &self.rows[id].children {
                    stack.push((*child, false));
                }
            }
        }
        out
    }

    pub fn pending_count(&self) -> usize {
        self.rows
            .iter()
            .filter(|row| row.kind == TreeRowKind::Package)
            .count()
    }

    pub fn unknown_count(&self) -> usize {
        self.rows
            .iter()
            .filter(|row| row.kind == TreeRowKind::UnknownDependency)
            .count()
    }
}

#[derive(Debug, Clone)]
struct Dependency {
    name: String,
    pending: Option<usize>,
    rank: u8,
}

fn resolve(
    package: &PackageView,
    index: &BTreeMap<&str, usize>,
    unique: &[&PackageView],
) -> Vec<Dependency> {
    let mut seen = BTreeSet::new();
    let mut dependencies = Vec::new();
    for name in &package.depends {
        if name.is_empty() || name == &package.name {
            continue;
        }
        if !seen.insert(name.as_str()) {
            continue;
        }
        match index.get(name.as_str()) {
            Some(target) => dependencies.push(Dependency {
                name: name.clone(),
                pending: Some(*target),
                rank: unique[*target].artifact.rank(),
            }),
            None => dependencies.push(Dependency {
                name: name.clone(),
                pending: None,
                rank: ArtifactState::Unknown.rank(),
            }),
        }
    }
    dependencies.sort_by(|left, right| {
        left.rank
            .cmp(&right.rank)
            .then_with(|| left.name.cmp(&right.name))
    });
    dependencies
}

fn package_order(packages: &[&PackageView]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..packages.len()).collect();
    order.sort_by(|left, right| {
        packages[*left]
            .artifact
            .rank()
            .cmp(&packages[*right].artifact.rank())
            .then_with(|| packages[*left].name.cmp(&packages[*right].name))
    });
    order
}

fn attach_package(
    rows: &mut Vec<TreeRow>,
    parent: Option<RowId>,
    package: &PackageView,
    depth: usize,
) -> RowId {
    let id = rows.len();
    let label = if package.available.is_empty() {
        package.name.clone()
    } else {
        format!("{} {}", package.name, package.available)
    };
    rows.push(TreeRow {
        id,
        parent,
        children: Vec::new(),
        depth,
        kind: TreeRowKind::Package,
        name: package.name.clone(),
        label,
        repo: package.repo.clone(),
        artifact: Some(package.artifact),
        artifact_at: package.artifact_at,
        available: if package.available.is_empty() {
            None
        } else {
            Some(package.available.clone())
        },
        detail: package.detail.clone(),
        size: package.download_bytes,
    });
    if let Some(parent) = parent {
        rows[parent].children.push(id);
    }
    id
}

fn attach_unknown(rows: &mut Vec<TreeRow>, parent: RowId, name: &str, depth: usize) -> RowId {
    let id = rows.len();
    rows.push(TreeRow {
        id,
        parent: Some(parent),
        children: Vec::new(),
        depth,
        kind: TreeRowKind::UnknownDependency,
        name: name.to_string(),
        label: name.to_string(),
        repo: Repo::Unknown,
        artifact: Some(ArtifactState::Unknown),
        artifact_at: None,
        available: None,
        detail: None,
        size: None,
    });
    rows[parent].children.push(id);
    id
}

struct Frame {
    row: RowId,
    package: usize,
    next: usize,
    depth: usize,
}

fn expand(
    rows: &mut Vec<TreeRow>,
    root_row: RowId,
    root_package: usize,
    packages: &[&PackageView],
    resolved: &[Vec<Dependency>],
    placed: &mut [bool],
    unknown: &mut BTreeSet<String>,
) {
    let mut stack = vec![Frame {
        row: root_row,
        package: root_package,
        next: 0,
        depth: 0,
    }];

    while let Some(frame) = stack.last() {
        let package = frame.package;
        let next = frame.next;
        let parent_row = frame.row;
        let depth = frame.depth + 1;
        if next >= resolved[package].len() {
            stack.pop();
            continue;
        }
        let dependency = resolved[package][next].clone();
        stack.last_mut().expect("frame exists").next += 1;

        if let Some(target) = dependency.pending {
            if placed[target] {
                continue;
            }
            placed[target] = true;
            let row = attach_package(rows, Some(parent_row), packages[target], depth);
            stack.push(Frame {
                row,
                package: target,
                next: 0,
                depth,
            });
        } else if unknown.insert(dependency.name.clone()) {
            attach_unknown(rows, parent_row, &dependency.name, depth);
        }
    }
}

fn sort_children(rows: &mut [TreeRow]) {
    let keys: Vec<(u8, String)> = rows
        .iter()
        .map(|row| {
            (
                row.artifact.map_or(0, |artifact| artifact.rank()),
                row.name.clone(),
            )
        })
        .collect();
    for row in rows {
        row.children
            .sort_by(|left, right| keys[*left].cmp(&keys[*right]));
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::{Tree, TreeError, TreeRow, TreeRowKind};
    use crate::frontier::{Edge, EdgeKind};
    use crate::report::{ArtifactState, PackageView, Repo};

    fn package(name: &str, artifact: ArtifactState, depends: &[&str]) -> PackageView {
        PackageView {
            name: name.to_string(),
            repo: Repo::Unknown,
            installed: "1.0.0-1".to_string(),
            available: "2.0.0-1".to_string(),
            download_bytes: None,
            artifact,
            artifact_at: None,
            detail: None,
            depends: depends.iter().map(|dep| (*dep).to_string()).collect(),
        }
    }

    fn find<'a>(tree: &'a Tree, name: &str) -> &'a TreeRow {
        tree.rows
            .iter()
            .find(|row| row.name == name)
            .unwrap_or_else(|| panic!("{name} is in the tree"))
    }

    fn child_names(tree: &Tree, row: &TreeRow) -> Vec<String> {
        row.children
            .iter()
            .map(|id| tree.rows[*id].name.clone())
            .collect()
    }

    fn display_names(tree: &Tree) -> Vec<&str> {
        tree.display_rows()
            .iter()
            .map(|row| row.name.as_str())
            .collect()
    }

    #[test]
    fn a_diamond_is_one_root_and_each_package_once() {
        let tree = Tree::build(&[
            package("base", ArtifactState::Cached, &[]),
            package("left", ArtifactState::Missing, &["base"]),
            package("right", ArtifactState::Missing, &["base"]),
            package("join", ArtifactState::Missing, &["left", "right"]),
        ])
        .expect("diamond is a forest");

        assert_eq!(tree.pending_count(), 4);
        assert_eq!(tree.unknown_count(), 0);
        assert_eq!(tree.roots, [find(&tree, "join").id]);

        let names: BTreeSet<&str> = tree
            .rows
            .iter()
            .filter(|row| row.kind == TreeRowKind::Package)
            .map(|row| row.name.as_str())
            .collect();
        assert_eq!(names.len(), 4);

        assert_eq!(find(&tree, "join").parent, None);
        assert_eq!(find(&tree, "left").parent, Some(find(&tree, "join").id));
        assert_eq!(find(&tree, "right").parent, Some(find(&tree, "join").id));
        assert_eq!(find(&tree, "base").parent, Some(find(&tree, "left").id));
        assert!(find(&tree, "base").children.is_empty());

        // Nom reverses the stored sibling and root order: right is the last
        // child and therefore the top row; join closes the frame.
        assert_eq!(display_names(&tree), ["right", "base", "left", "join"]);
    }

    #[test]
    fn the_tree_exposes_one_required_edge_per_pending_dependency() {
        let tree = Tree::build(&[
            package("base", ArtifactState::Missing, &[]),
            package("left", ArtifactState::Missing, &["base"]),
            package("right", ArtifactState::Missing, &["base"]),
            package("join", ArtifactState::Missing, &["left", "right", "glibc"]),
        ])
        .expect("diamond is a forest");

        assert_eq!(
            tree.edges,
            [
                Edge::new("left", "join", EdgeKind::Runtime, true),
                Edge::new("right", "join", EdgeKind::Runtime, true),
                Edge::new("base", "left", EdgeKind::Runtime, true),
                Edge::new("base", "right", EdgeKind::Runtime, true),
            ],
            "a join keeps both required edges; an unknown dependency adds none"
        );
    }

    #[test]
    fn two_independent_roots_are_two_roots_with_no_parent() {
        let tree = Tree::build(&[
            package("root-b", ArtifactState::Missing, &[]),
            package("root-a", ArtifactState::Cached, &[]),
        ])
        .expect("two roots are a forest");

        assert_eq!(
            tree.roots,
            [find(&tree, "root-a").id, find(&tree, "root-b").id]
        );
        assert_eq!(find(&tree, "root-a").parent, None);
        assert_eq!(find(&tree, "root-b").parent, None);
        assert_eq!(display_names(&tree), ["root-b", "root-a"]);
    }

    #[test]
    fn a_dependency_outside_the_pending_set_is_one_unknown_leaf() {
        let tree = Tree::build(&[package("app", ArtifactState::Missing, &["glibc", "app"])])
            .expect("one package is a forest");

        assert_eq!(tree.pending_count(), 1);
        assert_eq!(tree.unknown_count(), 1);
        assert_eq!(tree.roots, [find(&tree, "app").id]);

        let app = find(&tree, "app");
        assert_eq!(app.children.len(), 1);

        let leaf = find(&tree, "glibc");
        assert_eq!(leaf.kind, TreeRowKind::UnknownDependency);
        assert_eq!(leaf.artifact, Some(ArtifactState::Unknown));
        assert_eq!(leaf.parent, Some(app.id));
        assert!(leaf.children.is_empty());
        assert_eq!(
            tree.display_rows().last().map(|row| row.name.as_str()),
            Some("app")
        );
    }

    #[test]
    fn a_cycle_reachable_from_a_root_is_drawn_once() {
        let tree = Tree::build(&[
            package("root", ArtifactState::Cached, &["a"]),
            package("a", ArtifactState::Missing, &["b"]),
            package("b", ArtifactState::Missing, &["a"]),
        ])
        .expect("the root makes the cycle drawable");

        assert_eq!(tree.pending_count(), 3);
        assert_eq!(tree.roots, [find(&tree, "root").id]);
        assert_eq!(find(&tree, "a").parent, Some(find(&tree, "root").id));
        assert_eq!(find(&tree, "b").parent, Some(find(&tree, "a").id));
        assert_eq!(find(&tree, "b").children.len(), 0);
    }

    #[test]
    fn a_cycle_without_a_root_fails_deterministically() {
        let packages = [
            package("b", ArtifactState::Missing, &["a"]),
            package("a", ArtifactState::Missing, &["b"]),
        ];
        let error = Tree::build(&packages).expect_err("no root");

        assert_eq!(
            error,
            TreeError::Cycle {
                packages: vec!["a".to_string(), "b".to_string()]
            }
        );
        assert_eq!(error.to_string(), "dependency cycle has no root: a, b");
        assert_eq!(Tree::build(&packages).expect_err("stable"), error);

        // A valid root beside an unrooted cycle does not make the cycle
        // drawable; the whole forest still fails.
        let error = Tree::build(&[
            package("solo", ArtifactState::Cached, &[]),
            package("a", ArtifactState::Missing, &["b"]),
            package("b", ArtifactState::Missing, &["a"]),
        ])
        .expect_err("the cycle component has no root");
        assert_eq!(
            error,
            TreeError::Cycle {
                packages: vec!["a".to_string(), "b".to_string()]
            }
        );
    }

    #[test]
    fn a_self_edge_is_ignored_and_the_package_is_a_root() {
        let tree = Tree::build(&[package("solo", ArtifactState::Missing, &["solo"])])
            .expect("a self edge is not a cycle component");

        assert_eq!(tree.pending_count(), 1);
        assert_eq!(tree.unknown_count(), 0);
        assert_eq!(tree.roots, [find(&tree, "solo").id]);
        assert!(find(&tree, "solo").children.is_empty());
    }

    #[test]
    fn sibling_order_is_artifact_rank_then_name() {
        let tree = Tree::build(&[
            package(
                "parent",
                ArtifactState::Missing,
                &["missing", "cached", "partial", "gamma", "alpha"],
            ),
            package("partial", ArtifactState::Partial, &[]),
            package("cached", ArtifactState::Cached, &[]),
            package("missing", ArtifactState::Missing, &[]),
            package("gamma", ArtifactState::Missing, &[]),
            package("alpha", ArtifactState::Missing, &[]),
        ])
        .expect("one root is a forest");

        assert_eq!(
            child_names(&tree, find(&tree, "parent")),
            ["partial", "cached", "alpha", "gamma", "missing"]
        );
    }

    /// The 2,000-package pass from `NEXT.md` T4, as a regression gate.
    ///
    /// Two bounds, because there are two costs and they are paid at different
    /// rates. The frame is what a keypress or a live tick pays, and it is the
    /// `TUI.md` budget of 16 ms at 2,000 rows. Ingest is the one-shot plan plus
    /// a full 4,000-observation reduce: a burst, not a frame. Both bounds are
    /// the release measurements with the unoptimized test build's factor added,
    /// and both fail loudly on a quadratic step, which is what they catch.
    #[test]
    fn two_thousand_packages_plan_and_assemble_inside_the_frame_budget() {
        use std::time::{Duration, Instant, UNIX_EPOCH};

        use crate::frontier::Observed;
        use crate::report::{PrefetchReport, Section, Snapshot};
        use crate::tui::live::{LiveRun, LiveState, LiveView};

        const PACKAGES: usize = 2_000;
        // Ten layers of two hundred, like a real pending set, not one
        // 2,000-deep chain: a chain makes every prerequisite closure the whole
        // graph above it and measures a shape no AUR tree has.
        const LAYER: usize = 200;
        // Measured 56 ms debug / 10.5 ms release for a warm frame at 120x40,
        // best of three. The `TUI.md` budget is 16 ms, so release holds; the
        // first, cold frame is ~35 ms release and belongs to the separate
        // 100 ms first-paint budget.
        const FRAME_BUDGET: Duration = Duration::from_millis(250);
        // Measured 3.0 s debug / 443 ms release, and 14.3 s during a full
        // parallel run of this suite. `GraphState::recompute` rescans every
        // edge per observation, which is where this goes; the bound is loose
        // because the harness shares the machine with every other test.
        const INGEST_BUDGET: Duration = Duration::from_secs(30);

        let now = UNIX_EPOCH + Duration::from_secs(1_760_000_000);
        let name = |index: usize| format!("pkg-{index:04}");
        let packages: Vec<PackageView> = (0..PACKAGES)
            .map(|index| {
                let depends: Vec<String> = if index < LAYER {
                    Vec::new()
                } else {
                    let below = (index / LAYER - 1) * LAYER;
                    vec![
                        name(below + index % LAYER),
                        name(below + (index * 7 + 3) % LAYER),
                    ]
                };
                let depends: Vec<&str> = depends.iter().map(String::as_str).collect();
                let mut package = package(&name(index), ArtifactState::Missing, &depends);
                package.detail = Some("not in cache".to_string());
                package.download_bytes = Some(1_200_000);
                package
            })
            .collect();

        let tree_start = Instant::now();
        let tree = Tree::build(&packages).expect("the fixture is a forest");
        let tree_elapsed = tree_start.elapsed();

        let ingest_start = Instant::now();
        let mut run = LiveRun::plan_concurrent(&tree, now).expect("plan seeds");
        let mut reduced = 0usize;
        for index in 0..PACKAGES {
            let node = name(index);
            for kind in [Observed::Started, Observed::Finished] {
                let transitions = run
                    .observe(&node, kind, now, None, "observed")
                    .expect("the reducer accepts a seconds-granularity trace");
                reduced += transitions.len();
            }
        }
        let ingest = ingest_start.elapsed();

        let view_start = Instant::now();
        let view = LiveView::build_at(&tree, &run, now);
        let shown = view.window(&tree, 40).slots.len();
        let view_elapsed = view_start.elapsed();

        // The real frame, over the same 2,000-package snapshot: this is what a
        // keypress pays, forest and view rebuilds included.
        let snapshot = Snapshot {
            prefetch: Section::ready(
                PrefetchReport::new(packages, Some("mirror.example.org".to_string()), Vec::new()),
                now,
            ),
            actionable: 1,
            ..Snapshot::default()
        };
        let frame_start = Instant::now();
        let mut frame_text = crate::tui::render::render_live_frame(
            &snapshot,
            &run,
            120,
            40,
            crate::tui::render::RenderCtx::new(false, true),
            false,
        );
        let mut frame = frame_start.elapsed();
        // The suite runs in parallel, so the frame is the best of three: the
        // minimum is the least polluted sample and the bound stays honest.
        for _ in 0..2 {
            let start = Instant::now();
            frame_text = crate::tui::render::render_live_frame(
                &snapshot,
                &run,
                120,
                40,
                crate::tui::render::RenderCtx::new(false, true),
                false,
            );
            frame = frame.min(start.elapsed());
        }

        assert_eq!(tree.pending_count(), PACKAGES, "every package is planned");
        assert_eq!(tree.unknown_count(), 0, "no display-only dependency");
        // A finished node also releases its ready dependents, so the batch is
        // larger than the input trace.
        assert!(
            reduced >= 2 * PACKAGES,
            "every observation landed ({reduced} transitions)"
        );
        assert_eq!(view.rows.len(), PACKAGES, "one live row per package");
        assert!(
            view.rows.values().all(|row| row.state == LiveState::Done),
            "every package finished"
        );
        assert!(shown > 0, "the window keeps rows on a 2,000-row forest");
        assert!(
            frame_text.contains("Dependency Graph"),
            "the frame shows the forest header"
        );
        assert!(
            frame < FRAME_BUDGET,
            "the frame took {frame:?}; the budget is {FRAME_BUDGET:?} \
             (forest {tree_elapsed:?} + view {view_elapsed:?} of one frame)"
        );
        assert!(
            ingest < INGEST_BUDGET,
            "plan and reduce took {ingest:?}; the budget is {INGEST_BUDGET:?}"
        );
    }
}
