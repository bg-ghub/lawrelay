# LawRelay

[![CI](https://github.com/bg-ghub/lawrelay/actions/workflows/ci.yml/badge.svg)](https://github.com/bg-ghub/lawrelay/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-0.4.1-orange.svg)](CHANGELOG.md)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

LawRelay is a multilingual, lawyer-only marketplace for court cover and bounded legal assignments in Belgium.

Live beta: [lawrelay.be](https://lawrelay.be)

The repository is private during the founding beta. Only verified Belgian lawyers can enter the marketplace. Keep client names, case facts, documents, and privileged material outside LawRelay.

## Features

- Structured court-cover and legal assignments
- Verified lawyer and firm accounts
- Proposals, matching, notifications, and audited workflows
- NL/FR/DE/EN interface with English URL slugs
- Privacy requests, content reporting, admin MFA, and billing foundations

## Run locally

Requires Ruby 4.0.5, SQLite, libvips, and Chrome/Chromium for system tests.

```sh
bin/setup --skip-server
bin/rails db:seed
bin/rails server
```

On Windows, prefix binstubs with `ruby`, for example `ruby bin/rails server`.

Open `http://127.0.0.1:3000/nl`.

## Verify

```sh
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/bundler-audit check
bin/importmap audit
bin/rails zeitwerk:check
```

## Documentation

- [Release checklist](docs/release-master-todo.md)
- [LegalTribe product analysis](docs/legaltribe-product-brief.md)
- [Deployment](docs/ops/deployment.md)
- [Billing](docs/ops/billing.md)
- [Migadu email](docs/ops/migadu-email.md)
- [Security and access](docs/ops/secrets-and-access.md)

## License

LawRelay is open-source software licensed under the [GNU AGPL v3 or later](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
