# syntax=docker/dockerfile:1

ARG RUBY_VERSION=4.0.5
FROM ruby:${RUBY_VERSION}-slim AS base

WORKDIR /rails

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" \
    THRUSTER_HTTP_PORT=3000 \
    THRUSTER_TARGET_PORT=3001 \
    THRUSTER_FORWARD_HEADERS=true

# Runtime libraries only. TLS is terminated by Kamal Proxy, while Thruster
# supplies compression and static-file handling on the container port.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates \
      curl \
      libsqlite3-0 \
      libvips42 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

FROM base AS build

# Native gems and image processing need headers only while building.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libsqlite3-dev \
      libvips-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf /usr/local/bundle/cache /root/.bundle/cache

COPY . .

# Assets do not require a real secret or production credentials. The build
# context deliberately excludes master keys and all local runtime data.
RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile && \
    rm -rf tmp/cache

FROM base AS final

RUN groupadd --system --gid 1000 rails && \
    useradd --system --uid 1000 --gid rails --create-home --home-dir /rails rails

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /rails /rails

RUN mkdir -p /rails/storage /rails/tmp/pids /rails/log && \
    chown -R rails:rails /rails && \
    chmod 0755 /rails/bin/docker-entrypoint

USER rails

EXPOSE 3000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["./bin/thrust", "./bin/rails", "server"]
