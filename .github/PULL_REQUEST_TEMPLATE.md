<!-- Thanks for contributing to Slate! Keep PRs small and focused. -->

## What does this change?

<!-- A short description, and the issue it closes (e.g. "Closes #123"). -->

## Checklist

- [ ] `swift run SlateApp` builds and the app runs (free build)
- [ ] `./Scripts/verify.sh` passes (plist + build + tests)
- [ ] Change is small and focused; no unrelated refactoring
- [ ] Matches the surrounding style (monochrome, restrained; design tokens live in `slate-ui`)
- [ ] Anything touching the network is opt-in and respects Silent Mode
- [ ] No hard dependency on SlatePro from open code (route Pro logic through the `ProFeatures` seam)
