# MaterialX / scene graph example

These are small, locally authored fixtures; no external assets are needed.

1. In **Objects**, import `Panels.obj`. The hierarchy contains two mesh children and two named face subsets.
2. Select **Face**, open **Materials**, choose a subset, and import `Paint.mtlx`.
3. Edit `Graph/tint` or the mix inputs. Assign the imported Paint material to another subset to share those changes.
4. In **Objects**, create an instance and move it. It shares the original mesh asset; its subset bindings can be changed independently.
5. Save a `.vtrace` project to preserve the hierarchy, assignments, material program, and parameters.

The OBJ contains overlapping triangles on its second mesh to make grouping explicit. Move **Second** along Z to separate it from **Face**. This is a format/interaction fixture, not a production scene.
