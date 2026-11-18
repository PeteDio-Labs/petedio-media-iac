# ansible-tests

Source: `.github/workflows/ansible-tests.yml`

| | |
|---|---|
| **Trigger** | `pull_request`, `push` to `main`, `workflow_dispatch`. |
| **Runner** | GitHub-hosted (`ubuntu-latest`) |
| **Touches** | Nothing. Runs the recorded-answer guard tests under `ansible/tests/`; every play uses `connection: local`. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | Unfiltered on purpose so it always reports. Merging a change to a workflow file triggers `terraform` apply, because the push filter does not ignore `.github/workflows/**`. |
| **Run it** | Open a PR. |
