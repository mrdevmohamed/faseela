# Contributing

Contributions are welcome. The first step is choosing the repository that owns the change.

| Change | Repository |
|---|---|
| Add or update a package recipe, patch sources, or fix a package build | [faseela-repo](https://github.com/mrdevmohamed/faseela-repo) |
| Change Nawa's CLI, dependency resolver, archive format, or package engine | [nawa](https://github.com/mrdevmohamed/nawa) |
| Change bootstrap stages, rootfs/ISO assembly, installer, or release automation | [faseela](https://github.com/mrdevmohamed/faseela) |

## Checks before opening a pull request

Run the checks that match the change:

```sh
make check
make dry-run
```

Both are designed to run without building the entire distribution. A real build takes hours and needs root; mention it in the pull request when you have run one.

## Repository conventions

- A new or changed bootstrap script should have a corresponding test using stubbed tools where possible.
- Keep the `bootstrap/` layout stable. Workflows in the package repository call several scripts by their repository paths.
- If a change affects stage inputs, outputs, or invalidation, update the architecture and bootstrap documentation in the same change.
- Treat published artifact names and the rootfs seed contract as interfaces used by later builds and other repositories.
- Follow the shell conventions and lint checks described in the repository's [CONTRIBUTING.md](https://github.com/mrdevmohamed/faseela/blob/master/CONTRIBUTING.md).

For the full contribution rules, see the root [CONTRIBUTING.md](https://github.com/mrdevmohamed/faseela/blob/master/CONTRIBUTING.md).
