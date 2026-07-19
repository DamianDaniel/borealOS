# Contributing to borealOS

Thanks for contributing to **borealOS**.

This project follows a staged development workflow:

* `main` → stable branch
* `dev` → active integration branch
* Feature/fix branches → merged into `dev`
* `main` only receives changes through merges from `dev`

Please avoid opening PRs directly into `main`.

---

## Development Workflow

### 1. Fork and clone

```bash
git clone https://github.com/DamianDaniel/borealOS.git
cd borealOS
```

Add the upstream remote:

```bash
git remote add upstream https://github.com/DamianDaniel/borealOS.git
```

---

### 2. Create a branch from `dev`

Sync first:

```bash
git fetch upstream
git checkout dev
git pull upstream dev
```

Create your branch:

```bash
git checkout -b feat/short-description
```

Examples:

```text
feat/kernel-logging
fix/boot-timeout
docs/install-guide
refactor/config-loader
```

---

### 3. Make changes

General expectations:

* Keep commits focused
* Avoid unrelated formatting changes
* Prefer small PRs over large rewrites
* Document behavior changes
* Update tests/docs where appropriate

---

### 4. Test before opening PR

Run the project's build/test commands if available.

Example checklist:

* [ ] Project builds successfully
* [ ] Existing functionality still works
* [ ] New functionality tested
* [ ] Documentation updated
* [ ] No unnecessary files committed

---

### 5. Commit clearly

Recommended commit format:

```text
type(scope): short summary
```

Examples:

```text
feat(kernel): add boot diagnostics
fix(fs): prevent invalid mount state
docs(setup): update install instructions
```

Suggested types:

* `feat`
* `fix`
* `docs`
* `refactor`
* `test`
* `build`
* `chore`

---

### 6. Push and open a Pull Request

```bash
git push origin feat/short-description
```

Open a PR:

**Target branch → ****`dev`**

Include:

* What changed
* Why it changed
* Testing performed
* Screenshots/logs if relevant

---

## Pull Request Guidelines

PRs may be closed if they:

* Target `main`
* Mix unrelated changes
* Lack testing information
* Break build or existing behavior

---

## Reporting Issues

When opening an issue include:

```text
Environment:
Version:
Expected behavior:
Actual behavior:
Steps to reproduce:
Logs/screenshots:
```

---

## Code Style

Until formal standards are defined:

* Prefer readable code over clever code
* Keep functions focused
* Use consistent naming
* Document non-obvious decisions

---

## Questions

If you're unsure where work belongs, open an issue before implementing large changes.

Your BorealOS team and it's contributors.
