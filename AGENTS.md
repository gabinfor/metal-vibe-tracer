# Renderer direction

Keep the existing Swift/Metal renderer and extend it incrementally (user decision, 2026-09-04). Preserve its ReSTIR and MetalFX integration while adding material and texture capabilities. External libraries may supply components; replacing the rendering engine is outside the current direction. Proposed dependencies in `REFERENCES.md` remain unimplemented until actually integrated.

# Project references

Maintain `REFERENCES.md` alongside changes to rendering methods, borrowed formulas/code, datasets, and platform integrations. Follow its maintenance rules: verify primary sources, map citations to affected symbols, document adaptations, and distinguish implemented methods from related work. Preserve stable citation keys and any required upstream attribution notices. Update references in the same change as the implementation.

# Docs and code hygiene

Every change keeps the documentation and the code tidy (user decision, 2026-11-04):

- Update the affected docs in the same change: `README.md`, `docs/USER_GUIDE.md`, the design docs in `docs/`, and `CHANGELOG.md` for user-visible changes. Check names, paths, UI labels, defaults and limits against the code; don't leave claims you haven't verified.
- Leave touched code tidy: fix comments made stale by the change, describe current behaviour rather than history ("used to", "as before"), drop commented-out code, and remove code the change leaves unused (grep `tests/` too, since the GPU suite compiles against production symbols).
- Keep it simple: no drive-by refactors, renames or behaviour changes in a cleanup. Keep the harness marker `// 5. App Entry Point`, citation keys and Codable fields.
