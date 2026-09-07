# Renderer direction

Keep the existing Swift/Metal renderer and extend it incrementally (user decision, 2026-09-04). Preserve its ReSTIR and MetalFX integration while adding material and texture capabilities. External libraries may supply components; replacing the rendering engine is outside the current direction. Proposed dependencies in `REFERENCES.md` remain unimplemented until actually integrated.

# Project references

Maintain `REFERENCES.md` alongside changes to rendering methods, borrowed formulas/code, datasets, and platform integrations. Follow its maintenance rules: verify primary sources, map citations to affected symbols, document adaptations, and distinguish implemented methods from related work. Preserve stable citation keys and any required upstream attribution notices. Update references in the same change as the implementation.
