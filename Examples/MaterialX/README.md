# MaterialX / scene graph example

These are small, locally authored fixtures; no external assets are needed.

1. On the **Objects** tab, choose **Add Model…** and open `Panels.obj`. The hierarchy contains two mesh children and two named face subsets.
2. Select **Face**, open the **Materials** tab, choose a subset, and choose **Import MaterialX…** to open `Paint.mtlx`.
3. Edit the **Tint** input (`Graph/tint`) or the mix inputs. Assign the imported Paint material to another subset to share those changes.
4. On the **Objects** tab, choose **Create Instance** and move it. It shares the original mesh asset; its subset bindings can be changed independently.
5. Save a `.vtrace` project to preserve the hierarchy, assignments, material program, and parameters.

The OBJ contains overlapping triangles on its second mesh to make grouping explicit. Move **Second** along Z to separate it from **Face**. This is a format/interaction fixture, not a production scene.
