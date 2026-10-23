# Contributing

Thank you for your interest in Metal Vibe Tracer. Bug reports, measurements and pull requests are welcome.

## Licensing of contributions

By submitting a contribution, you agree that it is licensed under the project's [MIT License](LICENSE), and you confirm that you have the right to submit it under that license.

Third-party code, data or assets may be included only under licenses compatible with MIT, such as MIT, BSD, Apache-2.0, CC0 or CC-BY. Data under share-alike terms (CC BY-SA) must stay in separate files under its own license, as the CIE spectral tables do. Do not submit:

- code under the GPL, LGPL, AGPL or another copyleft license;
- code, data or assets restricted to non-commercial, research-only or evaluation use;
- code copied from a repository or website that has no license.

## References and notices

Update the following in the same pull request as the change:

- [REFERENCES.md](REFERENCES.md), when you add or change a rendering method, borrow a formula or code, or add a dataset or platform integration. Follow its maintenance rules: cite primary sources, map them to the affected symbols, describe adaptations, and keep stable citation keys.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), when you vendor, bundle or download third-party code, data or assets. Keep the upstream license text and copyright notices, record the source and pinned revision, and state what was modified.

Implementing a method from a paper is welcome. Cite the paper, and write the implementation yourself rather than copying the authors' code unless its license allows it.

## Before opening a pull request

```bash
./build.sh
python3 tests/verify.py
```

Changes to default rendering behaviour should include equal-time measurements; see [tests/PERFORMANCE.md](tests/PERFORMANCE.md) and the Development section of the [README](README.md#development).
