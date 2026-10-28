# Contributing to LawRelay

Thanks for helping improve LawRelay. This is pre-release software for a sensitive professional context, so privacy and authorization boundaries are part of every change.

## Before you start

- Open an issue for substantial product, data-model, security, billing, or legal-workflow changes.
- Never include real client names, case facts, pleadings, privileged communications, credentials, or production data in an issue, fixture, screenshot, commit, or pull request.
- Use synthetic `.test` email addresses and invented firms in tests and examples.
- Report security issues through GitHub private vulnerability reporting, not a public issue.

## Development

Follow the setup instructions in `README.md`, then run:

```sh
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/bundler-audit check
bin/importmap audit
bin/rails zeitwerk:check
```

Use `ruby bin/...` for each command on Windows.

Pull requests should explain the user-visible outcome, data/security impact, test coverage, and any migration or rollback considerations. Keep changes focused and preserve all firm, participant, and administrator authorization checks.

## Versioning and releases

LawRelay follows Semantic Versioning:

- patch (`0.1.1`): backward-compatible fixes;
- minor (`0.2.0`): backward-compatible features while the product remains in initial development;
- major (`1.0.0`): the first stable public contract; later breaking changes increment the major version.

The canonical version is the root `VERSION` file. Release tags use the same version prefixed with `v`, and every release updates `CHANGELOG.md`.

## License

By contributing, you agree that your contribution is licensed under the GNU Affero General Public License v3.0 or later, as described in `LICENSE`.
